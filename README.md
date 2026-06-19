# Angular host + web-component subtree routing

A minimal stand demonstrating how an **Angular** application can host a **web component**
that runs its **own client-side router** over a delegated slice of the URL space — using
only modern browser primitives, with no coupling between the two routers.

> Versions pinned to the latest stable releases as of **2026-06-19**: Angular 22, Lit 3.3,
> TypeScript 6, Bun 1.3, Node 24.15.

## The problem

The Angular router owns the app's paths. One branch of the route tree — `/feature/**` — must
be handed over wholesale to a web component, which then drives its **own** routing for every
sub-path (`/feature`, `/feature/item/2`, …) without Angular re-rendering or the page
reloading. The two routers must not fight over the URL.

## The solution

```
┌─────────────────────────────────────────────────────────────────────┐
│ host-app (Angular 22)                                                 │
│   routes: '', 'about', <matcher: /feature/**>, '**'                   │
│                                                                       │
│   FEATURE_BASE ── single source of truth for the mount path           │
│   featureMatcher  ── consumes the WHOLE subtree into one route         │
│                       node → component is never re-created            │
│                                                                       │
│   <feature-app [base]="FEATURE_BASE">  ◄── CUSTOM_ELEMENTS_SCHEMA      │
│        │                                                              │
│        ▼                                                              │
│   ┌───────────────────────────────────────────────────────────────┐ │
│   │ feature-web-component  (root element + routes.ts + view comps) │ │
│   │   routes.ts: pattern → lambda(ctx) → <feature-list/item/…>       │ │
│   │   ┌─────────────────────────────────────────────────────────┐  │ │
│   │   │ subtree-router  (generic: match → render lambda → commit)│  │ │
│   │   │   Navigation API  → intercept() navigations under base   │  │ │
│   │   │   URLPattern      → match routes + extract :params       │  │ │
│   │   └─────────────────────────────────────────────────────────┘  │ │
│   └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

Three independent repositories, assembled into one monorepo:

| Package | Repo | Role |
|---|---|---|
| `@igor-ganov/subtree-router` | `router-lib/` | View-library-agnostic router (Navigation API + URLPattern + commit adapter) |
| `@igor-ganov/feature-web-component` | `web-component/` | `<feature-app>` **Lit** element that consumes the router |
| `host-app` | `host-app/` | Angular 22 app that delegates `/feature/**` to the element |

### Why it works without conflict

1. **Angular side — one route for the whole subtree.** A custom
   [`UrlMatcher`](host-app/src/app/feature/feature.config.ts) consumes *all* segments under
   `FEATURE_BASE`. Because every sub-path resolves to the same route node, Angular reuses the
   host component instance — the embedded web component is **never destroyed** on internal
   navigation.

2. **Web-component side — the Navigation API.** The
   [`subtree-router`](router-lib/src/index.ts) listens to the global `navigate` event and
   calls `event.intercept()` **only** for destinations under its `base`. Internal links
   become same-document transitions; Angular (which listens to `popstate`, not the
   `navigate` event) never sees them. Navigations that leave the subtree are left untouched,
   so Angular handles them normally.

3. **The web component is mount-agnostic.** It contains no hard-coded path. The host owns the
   mount path as a single constant (`FEATURE_BASE`), used both by the matcher and *injected*
   into the element via the `[base]` property binding. Mount it at `/admin` by changing one
   line on the host — the web-component package never changes. (The root element creates its
   router in Lit's `updated`, since the host sets `base` as a property *after*
   `connectedCallback` and the outlet exists only after the first render.)

4. **Re-entry stays robust.** Because the web component can advance the URL behind Angular's
   back, the host enables `onSameUrlNavigation: 'reload'`, so clicking back into the subtree
   always produces a navigation the component can pick up.

All five behaviours are verified in a real browser: deep-link on first load, internal
navigation, browser back/forward, leaving the subtree, and re-entering it — none of which
triggers a page reload.

### Inside the web component

Routes are declared once in [`web-component/src/routes.ts`](web-component/src/routes.ts) as
`pattern → lambda(ctx) → component`, with route params propagated into each page via Lit
property bindings. Every page is its own Lit element in `web-component/src/views/`, and the
router is initialised at the app root, not inside any page.

The **Counter** tab additionally shows shared state with [`@lit-labs/signals`](https://www.npmjs.com/package/@lit-labs/signals):
a single signal is displayed in the root element's header and mutated from the child page —
no prop drilling or events, and the value survives tab navigation.

## DX with the monorepo

- **Runtime:** [Bun](https://bun.sh) workspaces. One `bun install` at the root links the
  three packages via `workspace:*` symlinks — edit a library and the host picks it up.
- **No bundler for the libraries:** each compiles with `tsc` straight to ESM + `.d.ts`.
  Angular's esbuild bundles them transitively through the workspace symlink.
- **Topology:** the three packages are **independent git repos**, joined into this monorepo
  as **git submodules**. You get atomic local development *and* per-package publishing.

### Commands

```bash
bun install            # install + link the whole workspace
bun run build:libs     # build router-lib, then web-component (order matters)
bun run start          # build libs, then `ng serve` the host on :4200
bun run typecheck      # type-check both libraries
```

Open <http://localhost:4200> and try the **Feature** tab (its **Items** / **Counter** tabs),
or deep-link straight to <http://localhost:4200/feature/item/2>.

## Publishing to github.com/igor-ganov

The three packages are scaffolded locally as plain directories (so Bun can link them). The
[`publish.ps1`](publish.ps1) script turns them into published GitHub repos under
`igor-ganov` and wires them back as submodules of this monorepo. It does **not** run
automatically — review it, make sure `gh auth status` shows you signed in as `igor-ganov`,
then run it yourself:

```powershell
gh auth status                     # confirm the right account
pwsh ./publish.ps1                 # creates 4 repos, pushes, wires submodules
```

See the script header for what each step does and how to undo it.
