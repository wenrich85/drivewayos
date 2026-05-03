defmodule DrivewayOS.Onboarding.Steps.PickerStep do
  @moduledoc """
  Macro for wizard steps that render an N-card picker over a
  provider category. Generates `complete?/1`, `render/1`, `submit/2`,
  and `providers_for_picker/1` from a `category:` + `intro_copy:` arg.

  Using-step modules MUST declare `id/0` and `title/0` themselves —
  those vary per step and are not generated. The three generated
  callbacks (`complete?/1`, `render/1`, `submit/2`) are
  `defoverridable` so future divergence is possible.

  Example:

      defmodule DrivewayOS.Onboarding.Steps.Payment do
        use DrivewayOS.Onboarding.Steps.PickerStep,
          category: :payment,
          intro_copy: "Pick the payment processor..."

        @impl true
        def id, do: :payment

        @impl true
        def title, do: "Take card payments"
      end

  Render contract: each card displays the provider's
  `display.title`, `display.blurb`, optional perk paragraph (when
  `Affiliate.perk_copy/1` is non-nil), and an anchor CTA pointing
  at `display.href`. Cards stack vertically below `md:`, lay out as
  a 2-column grid above. UX rules from MASTER + ui-ux-pro-max:
  44px touch targets (`min-h-[44px]`), `motion-reduce:transition-none`,
  `text-slate-600` muted body, `border-slate-200`,
  `aria-label` on each anchor.

  ## Implementation note

  `~H` cannot be embedded inside a `quote do` block because the sigil
  checks `Macro.Env.has_var?(__CALLER__, {:assigns, nil})` at expansion
  time, and the caller when expanding `quote` is the *macro* module, not
  the using module. Instead we call `Phoenix.LiveView.TagEngine.compile/2`
  directly, passing the using-module's `__CALLER__` environment (patched
  with `function: {:render, 1}` so `HTMLEngine.annotate_body/1` can
  pattern-match it). The result is injected via `unquote` into the
  generated `render/1` function body — identical to what `~H` produces.
  """

  @template """
  <div class="space-y-4">
    <p class="text-sm text-slate-600">{@intro_copy}</p>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <%= for card <- @cards do %>
        <div class="card bg-base-100 shadow-md border border-slate-200 transition-shadow motion-reduce:transition-none hover:shadow-lg">
          <div class="card-body p-6 space-y-3">
            <h3 class="text-lg font-semibold text-slate-900">{card.title}</h3>
            <p class="text-sm text-slate-600 leading-relaxed">{card.blurb}</p>
            <%= if perk = DrivewayOS.Onboarding.Affiliate.perk_copy(card.id) do %>
              <p class="text-xs text-success font-medium">{perk}</p>
            <% end %>
            <a
              href={card.href}
              class="btn btn-primary min-h-[44px] gap-2 motion-reduce:transition-none"
              aria-label={"Connect " <> card.title}
            >
              {card.cta_label}
              <span class="hero-arrow-right w-4 h-4" aria-hidden="true"></span>
            </a>
          </div>
        </div>
      <% end %>
    </div>
  </div>
  """

  defmacro __using__(opts) do
    category = Keyword.fetch!(opts, :category)
    intro_copy = Keyword.fetch!(opts, :intro_copy)

    # Patch the caller env with a function context so HTMLEngine.annotate_body/1
    # can pattern-match it (it expects `function: {name, arity}`; at module
    # top-level __CALLER__.function is nil).
    caller = %{__CALLER__ | function: {:render, 1}}

    # Compile the HEEx template in the using-module's caller context.
    # This is equivalent to ~H but without the has_var? guard that prevents
    # ~H from being used inside quote blocks.
    compiled_template =
      Phoenix.LiveView.TagEngine.compile(@template,
        file: caller.file,
        line: caller.line + 1,
        caller: caller,
        indentation: 0,
        tag_handler: Phoenix.LiveView.HTMLEngine
      )

    quote do
      @behaviour DrivewayOS.Onboarding.Step

      use Phoenix.Component

      alias DrivewayOS.Onboarding.{Affiliate, Registry}
      alias DrivewayOS.Platform.Tenant

      @category unquote(category)
      @intro_copy unquote(intro_copy)

      @impl true
      def complete?(%Tenant{} = tenant) do
        Registry.by_category(@category)
        |> Enum.any?(& &1.setup_complete?(tenant))
      end

      @impl true
      # `var!` suppresses the unused-variable warning Elixir raises inside
      # `quote do` when a variable is only ever rebound, never read directly.
      # Plain `assigns` would trigger the warning at expansion time.
      def render(var!(assigns)) do
        var!(assigns) = Phoenix.Component.assign(var!(assigns), :intro_copy, @intro_copy)

        var!(assigns) =
          Phoenix.Component.assign(
            var!(assigns),
            :cards,
            providers_for_picker(var!(assigns).current_tenant)
          )

        unquote(compiled_template)
      end

      @impl true
      def submit(_params, socket), do: {:ok, socket}

      defp providers_for_picker(tenant) do
        Registry.by_category(@category)
        |> Enum.filter(& &1.configured?())
        |> Enum.reject(& &1.setup_complete?(tenant))
        |> Enum.map(fn mod -> Map.put(mod.display(), :id, mod.id()) end)
      end

      defoverridable complete?: 1, render: 1, submit: 2
    end
  end
end
