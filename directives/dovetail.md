---
id: R-DOVETAIL
opcode: DOVETAIL
alias: K
tier: public
slice: panel
rule: a panel is a Svelte component in TypeScript and token classes; seams go through Dovetail
when: [path:**/*.svelte]
enforce: check:CK-PANEL
---
# DOVETAIL: free inside the slot, bound at its edge

A panel slice is one Svelte component. It is free inside its slot: markup,
internal components, local state, copy, visual treatment and motion are the
student's. Every effect that crosses the slot's edge goes through the
Dovetail primitive the brief names, because that is what lets ten panels
built by ten people fuse into one application that works the first time.

The component:

- Line 1 is the `<!-- reach <cutout> <slice> -->` header Reach wrote; keep it.
- `<script lang="ts">` with strict types: no `any`, no `@ts-ignore`.
- Tailwind classes from the token vocabulary only: no arbitrary values
  (`p-[13px]`, `bg-[#123456]`), no raw colours, no `:global`, no literal
  `id=` attributes, no `vh`/`vw` sizes, no `z-index`, no `position: fixed`.
- Every declared view renders all five states: loading, empty, error,
  unavailable and ready. A blank area when data is missing is a failure.
- Text through the message catalogue with the module prefix
  (`t('finance.dashboard.title')`), never a bare string a locale cannot
  translate.

The seams, and the only door through each:

| Effect | Use | Never |
| --- | --- | --- |
| overlays | `openOverlay`, `<Overlay>` | `position: fixed`, `showModal`, body scroll lock |
| routes | `navigate`, `link`, `useRoute` | `window.location`, `history.*` |
| storage | `store(key)` | `localStorage`, `sessionStorage`, `indexedDB`, cookies |
| other panels | `emit`, `on` with declared events | imports from another module, `postMessage`, DOM events |
| backend | the generated client | `fetch`, `XMLHttpRequest`, `EventSource`, `WebSocket` |
| shortcuts | `shortcut` | `keydown` on `window`/`document`, `<svelte:window>` |
| timers | `every`, `after`, `frame` | `setInterval`, `setTimeout`, `requestAnimationFrame` |
| ids | `useId` | literal `id=`, literal ARIA references |

`reach check` reports CK-PANEL for each of these with the Dovetail rule id,
and the shape check adds the contract's own findings. When a request cannot
fit the shape, say which boundary it crosses and offer the closest version
that fits, starting with the student's design adjusted to comply.
