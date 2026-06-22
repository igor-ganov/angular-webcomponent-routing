# Angular host + web-component subtree routing

A minimal stand demonstrating how an **Angular** application can host a **web component**
that runs its **own client-side router** over a delegated slice of the URL space — using
only modern browser primitives, with no coupling between the two routers.

> Versions pinned to the latest stable releases as of **2026-06-19**: Angular 22, Lit 3.3,
> TypeScript 6, Bun 1.3, Node 24.15.

**▶ Live demo:** <https://igor-ganov.github.io/angular-webcomponent-routing/>

## Quick start

### Run this demo

```bash
git clone --recursive https://github.com/igor-ganov/angular-webcomponent-routing.git
cd angular-webcomponent-routing
bun install && bun run start
```

Open <http://localhost:4200>, switch to the **Feature** tab (its **Items** / **Counter**
tabs), or deep-link straight to <http://localhost:4200/feature/item/2> — internal navigation
never reloads the page. `--recursive` is required: the three packages are git submodules.

### Wire it into your own project

The engine [`@igor-ganov/subtree-router`](router-lib/src/index.ts) owns a *subtree* of the URL
(everything under `base`) and knows nothing about your view layer — you connect it with one
`commit(view, outlet)` adapter. A route is just `pattern + lambda(ctx) → view`. Navigations
outside `base` are left untouched, so the host router keeps its own paths.

```ts
// the entire public API
createSubtreeRouter<TView>({
  base,      // path prefix this router owns, e.g. "/feature"
  routes,    // [{ pattern, render: (ctx) => view }] — pattern is relative to base: "", "item/:id"
  outlet,    // the HTMLElement the active view is committed into
  commit,    // (view, outlet) => void — your view layer: Lit `render`, React root, replaceChildren…
  fallback,  // optional (ctx) => view when nothing matches
})           // → { navigate(path), dispose() }
// render lambdas receive ctx = { params, base, url }
```

**On the web-component side** (4 steps):

1. **Declare routes in one file** — `pattern → lambda(ctx) → component`, params flow in via
   bindings. This is the only place routes live:
   ```ts
   export const routes = [
     { pattern: '',         render: ({ base })         => html`<feature-list .base=${base}></feature-list>` },
     { pattern: 'item/:id', render: ({ params, base }) => html`<feature-item .itemId=${params['id'] ?? ''} .base=${base}></feature-item>` },
   ];
   ```
2. **Pick the commit adapter** for your view layer and build the router:
   ```ts
   const litCommit = (view, outlet) => render(view, outlet);
   export const createAppRouter = (base, outlet) =>
     createSubtreeRouter({ base, routes, fallback, outlet, commit: litCommit });
   ```
3. **The root element owns the outlet and starts the router.** It is **mount-agnostic** — the
   host injects the path via a `base` property; the element hard-codes nothing. Create the
   router in `updated` (the host sets `base` *after* `connectedCallback`, and the outlet exists
   only after the first render), and `dispose()` it on disconnect:
   ```ts
   @property({ type: String }) base = '';
   updated(changed) { if (changed.has('base') && this.base !== '') this.#setupRouter(); }
   disconnectedCallback() { super.disconnectedCallback(); this.#router?.dispose(); }
   render() { return html`… <main class="outlet"></main>`; }
   ```
4. **Internal links are plain `<a href>`** — the Navigation API turns clicks into same-document
   transitions, so the host never sees them. Build hrefs from `base` (`toHref(base, 'counter')`).

**On the Angular host side** (3 steps):

1. **Consume the whole subtree with one `UrlMatcher`** — so every sub-path resolves to the same
   route node and Angular *never destroys* the embedded element on internal navigation:
   ```ts
   const baseHref = new URL(document.baseURI).pathname.replace(/\/$/, '');
   export const FEATURE_BASE = `${baseHref}/feature`;        // /feature locally, /repo/feature on Pages
   export const featureMatcher = (segments) =>
     segments[0]?.path === 'feature' ? { consumed: segments } : null;
   ```
2. **Register the matcher and inject `base` into the element** (`CUSTOM_ELEMENTS_SCHEMA` lets the
   template name an unknown tag):
   ```ts
   { matcher: featureMatcher, component: FeatureHost }       // in your Routes
   // FeatureHost template: <feature-app [base]="FEATURE_BASE"></feature-app>
   ```
3. **Register the element + enable same-URL reload:**
   ```ts
   import '@igor-ganov/feature-web-component';               // side-effect import in main.ts, before bootstrap
   provideRouter(routes, withRouterConfig({ onSameUrlNavigation: 'reload' }))
   ```

Everything that changes between projects is `FEATURE_BASE` and the routes table. The engine is
never touched, and the web component drops into any host because the mount path is injected from
outside. To mount at `/admin` instead, change one constant on the host.

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

## Repositories (github.com/igor-ganov)

Published as one monorepo of three submodules:

| Repo | Contents |
|---|---|
| [`angular-webcomponent-routing`](https://github.com/igor-ganov/angular-webcomponent-routing) | this monorepo (submodules + bun workspace) |
| [`subtree-router`](https://github.com/igor-ganov/subtree-router) | `router-lib/` |
| [`feature-web-component`](https://github.com/igor-ganov/feature-web-component) | `web-component/` |
| [`angular-host`](https://github.com/igor-ganov/angular-host) | `host-app/` |

Clone with submodules, then install and run:

```bash
git clone --recursive https://github.com/igor-ganov/angular-webcomponent-routing.git
cd angular-webcomponent-routing
bun install && bun run start
```

[`publish.ps1`](publish.ps1) reproduces the publish step (create repos, push, wire
submodules); it is idempotent. Confirm `gh` is signed in as `igor-ganov` before running it.

### Deploying to GitHub Pages

Pages serves a project repo under a sub-path, so the app is built with a matching
`--base-href`. The web component's mount path is derived from `<base href>` at runtime
(`feature.config.ts`), so the same code works locally (`/feature`) and on Pages
(`/angular-webcomponent-routing/feature`). A `404.html` (copy of `index.html`) provides the
SPA deep-link fallback.

```bash
bun run build:libs
bun --cwd host-app run build -- --base-href=/angular-webcomponent-routing/
cd host-app/dist/host-app/browser
cp index.html 404.html && : > .nojekyll          # SPA fallback + disable Jekyll
# publish the folder to the gh-pages branch (served at the Pages URL)
```
