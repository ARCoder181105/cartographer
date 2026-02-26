# 🗺️ Cartographer — ROADMAP

This roadmap is organized into phases. Each phase has a clear milestone — a working, testable artifact you can point to. Do not move to the next phase until the current milestone is solid.

---

## Phase 0 — Project Bootstrap (Week 1)

**Goal:** Get the repo skeleton, build tooling, and CI in place before writing any real code.

### Tasks
- [ ] Initialize monorepo with `parser/`, `engine/`, `frontend/`, `shared/`, `docs/` directories
- [ ] Set up C++ build with CMake (parser target)
- [ ] Set up Go module (`go.mod`) for engine
- [ ] Set up Vite + TypeScript project for frontend
- [ ] Add a root `Makefile` that builds all three layers with `make all`
- [ ] Set up GitHub Actions CI: build + basic smoke tests on push
- [ ] Write `BINARY_FORMAT.md` spec before writing any code that touches the format
- [ ] Write `ALGORITHMS.md` with pseudocode for Fruchterman-Reingold and BFS before implementing them

**Milestone:** `make all` succeeds from root. Three "hello world" programs build cleanly.

---

## Phase 1 — C++ Parser: Lexer (Weeks 2–3)

**Goal:** A correct, fast lexer for Go source code that tokenizes any `.go` file.

### What You're Building
A hand-written **lexer** (tokenizer) — the first stage of parsing. It reads raw source text and emits a flat stream of typed tokens: `IDENT`, `FUNC`, `LPAREN`, `STRING_LIT`, `PACKAGE`, etc.

### Tasks
- [ ] Define the token enum covering all Go keywords, operators, literals
- [ ] Implement `Lexer` class: character-by-character scanner with line/column tracking
- [ ] Handle edge cases: multi-line strings, raw string literals, nested comments
- [ ] Write token stream printer for debugging
- [ ] Unit test: lex 10 real `.go` files from the Go stdlib, verify token counts and spot-check output
- [ ] Benchmark: should tokenize 100k lines/second minimum

### Notes
Start with Go before TypeScript — Go's grammar is simpler and more regular. TypeScript has ASI (automatic semicolon insertion), template literals, and generics that complicate lexing significantly.

**Milestone:** Lex `net/http/server.go` from Go stdlib without errors. Print the token stream to stdout.

---

## Phase 2 — C++ Parser: AST + Call Graph Extraction (Weeks 4–6)

**Goal:** A recursive descent parser that reads tokens and extracts the information Cartographer needs — not a full language AST.

### What You're Building
A **partial parser** — you only parse what you need. You do not need to parse every expression or statement. You need:

- Package declarations and import paths
- Function and method definitions (name, receiver type, file, line start, line end)
- Function call expressions (caller → callee name)
- Cyclomatic complexity per function (count of `if`, `for`, `switch`, `select`, `case`, `&&`, `||` inside each function body)

### Tasks
- [ ] Implement `Parser` class consuming a token stream
- [ ] Parse package clause and import block (to resolve inter-file dependencies)
- [ ] Parse function/method declarations — track brace depth to find body boundaries
- [ ] Inside function bodies, identify call expressions (`identifier(` or `expr.identifier(`)
- [ ] Count cyclomatic complexity branches as you scan the body
- [ ] Build in-memory `Graph` object: nodes (functions/files), directed edges (calls/imports)
- [ ] Handle cross-package calls — record them as unresolved edges initially
- [ ] Implement a second pass to resolve cross-package edges using import path → file mapping
- [ ] Unit tests: parse `net/http` package, assert known function calls are present
- [ ] Stress test: parse entire Go stdlib (1200+ files), no crashes or panics

### Complexity Metric
Cyclomatic complexity = 1 + (number of decision points in function body). Decision points: `if`, `else if`, `for`, `range`, `switch`, each `case`, `select`, each `case`, `&&`, `||`.

**Milestone:** Run on the Go standard library. Print: file count, function count, top 20 most complex functions by cyclomatic complexity. Results should match expectations (e.g., `net/http/server.go` is known to be complex).

---

## Phase 3 — C++ Emitter: Binary Graph Format (Week 7)

**Goal:** Serialize the in-memory graph to a compact binary format (`.cgraph`).

### Binary Format Spec (`.cgraph`)

```
[HEADER]
  magic:       4 bytes  = 0x43475048 ("CGPH")
  version:     2 bytes  = 0x0001
  node_count:  4 bytes  (uint32)
  edge_count:  4 bytes  (uint32)
  flags:       2 bytes  (reserved)
  padding:     2 bytes

[STRING TABLE]
  str_table_size:  4 bytes (uint32, total bytes)
  str_data:        N bytes (null-terminated strings, concatenated)

[NODE TABLE]   — node_count entries, each 32 bytes
  name_offset:    4 bytes  (index into string table)
  file_offset:    4 bytes  (index into string table)
  line_start:     4 bytes  (uint32)
  line_end:       4 bytes  (uint32)
  complexity:     2 bytes  (uint16, cyclomatic)
  churn:          2 bytes  (uint16, 0–65535, populated by Go engine from git)
  node_type:      1 byte   (0=file, 1=function, 2=method)
  padding:        7 bytes

[EDGE TABLE]   — edge_count entries, each 12 bytes
  src_node:   4 bytes  (uint32, index into node table)
  dst_node:   4 bytes  (uint32, index into node table)
  edge_type:  1 byte   (0=call, 1=import)
  weight:     2 bytes  (uint16, call frequency if known, else 1)
  padding:    1 byte
```

### Tasks
- [ ] Implement `Emitter` class that walks the Graph and writes `.cgraph` binary
- [ ] Implement a C++ reader for validation (read back and verify node/edge counts)
- [ ] Write a Go reader for the binary format (used by the engine)
- [ ] Write format spec to `shared/format/BINARY_FORMAT.md`
- [ ] Fuzz test the Go reader: feed random bytes, ensure no panics

**Milestone:** Emit the Go stdlib graph to a `.cgraph` file. Read it back in Go and print node/edge counts. They should match.

---

## Phase 4 — Go Engine: Graph Data Structures (Week 8)

**Goal:** In-memory graph representation in Go that the layout and query layers will use.

### Tasks
- [ ] Define `Node` struct: ID, name, file, line range, complexity, churn, x/y position
- [ ] Define `Edge` struct: src, dst, type, weight
- [ ] Define `Graph` struct: node slice, edge slice, adjacency list (both forward and reverse)
- [ ] Implement `.cgraph` binary reader (from Phase 3 spec)
- [ ] Build adjacency list from edge table after loading
- [ ] Write `graph.Stats()` — node count, edge count, avg degree, max complexity node
- [ ] Validate: load the Go stdlib graph, print stats, ensure counts match the parser output

**Milestone:** `go run . --graph stdlib.cgraph --stats` prints correct statistics.

---

## Phase 5 — Go Engine: Fruchterman-Reingold Layout (Weeks 9–10)

**Goal:** Every node gets an (x, y) coordinate where proximity means coupling.

### The Algorithm

Fruchterman-Reingold is a physics simulation:

1. Place all nodes at random positions in a 2D field of width W and height H
2. Compute an ideal spring length `k = C * sqrt(area / node_count)` where C ≈ 1.0
3. For each iteration:
   - **Repulsive forces:** For every pair (u, v), compute a repulsive force proportional to `k² / distance(u,v)`. Push nodes apart.
   - **Attractive forces:** For every edge (u, v), compute an attractive force proportional to `distance(u,v)² / k`. Pull connected nodes together.
   - **Update positions:** Move each node by its net force vector, clamped by a temperature `t`
   - **Cool:** Reduce temperature `t` each iteration (simulated annealing). `t = t_initial * (1 - iteration/max_iterations)`
4. Stop when temperature reaches ~0 or after `max_iterations`

### Implementation Notes
- Use `float64` throughout
- For large graphs (>10k nodes), skip repulsion calculations for distant pairs — use a grid-based spatial index (divide space into cells, only compute repulsion within nearby cells). This reduces O(n²) to O(n log n).
- Run on a goroutine per iteration step, or parallelize the force computation with `sync.WaitGroup`
- Store final positions as `(x, y float64)` on each Node, normalized to [0, 10000] range

### Tasks
- [ ] Implement `layout.Run(graph, iterations int) error` function
- [ ] Implement repulsive force calculation (with spatial grid optimization)
- [ ] Implement attractive force calculation (only iterate over edge list)
- [ ] Implement temperature cooling schedule
- [ ] Expose progress via channel: `layout.RunWithProgress(graph, iters, progressCh)`
- [ ] Test: run on a 100-node random graph, verify visually that connected nodes cluster
- [ ] Benchmark: full layout of 5000-node graph should complete in < 30 seconds
- [ ] Persist final node positions back into the `.cgraph` file (add a positions section to the format)

**Milestone:** Run layout on Go stdlib graph. Export positions to JSON. Load in a quick HTML/Canvas sketch and verify clusters look meaningful.

---

## Phase 6 — Go Engine: Query Server (Weeks 11–12)

**Goal:** An HTTP server the frontend talks to. Queries must respond in < 50ms for graphs up to 10k nodes.

### API Endpoints

```
GET  /api/graph/stats
     → { node_count, edge_count, max_complexity, most_coupled_file }

GET  /api/nodes?limit=N&sort=complexity|churn|degree
     → [{ id, name, file, x, y, complexity, churn, degree }, ...]

GET  /api/nodes/:id
     → { id, name, file, line_start, line_end, complexity, churn, x, y, neighbors: [...] }

GET  /api/nodes/:id/radius?r=500
     → [nodes within spatial radius R of node id's position]

GET  /api/path?from=:id&to=:id
     → { path: [node_id, ...], length: N }  (BFS shortest path)

GET  /api/search?q=string
     → [{ id, name, file, score }]  (fuzzy name match, sorted by relevance)

GET  /api/git/churn?commits=30
     → [{ file, churn_score }, ...]  (parse git log, score by change frequency)

GET  /api/history?commits=20
     → [{ commit_hash, timestamp, changes: [{file, added, removed}] }]

GET  /api/graph/snapshot?commit=:hash
     → Full graph state at that commit (requires re-parsing or caching)

WS   /ws/watch
     → WebSocket: push node updates when filesystem changes are detected
```

### Tasks
- [ ] Implement HTTP server using Go's `net/http` (no framework)
- [ ] Implement BFS for `/api/path` — return shortest call path between two functions
- [ ] Implement spatial radius query using a k-d tree or grid index on (x, y) positions
- [ ] Implement fuzzy search (trigram index or simple substring with score)
- [ ] Implement git log parser: `git log --name-only --format="%H %at"` → churn scores per file
- [ ] Add CORS headers for frontend development
- [ ] Add WebSocket handler for filesystem watch events (use `fsnotify`)
- [ ] On file change: re-invoke C++ parser on that single file, diff edges, update graph, push update via WebSocket
- [ ] Write integration tests: spin up server, hit endpoints, assert response shape

**Milestone:** `curl http://localhost:8080/api/nodes?limit=20&sort=complexity` returns the 20 most complex nodes in the stdlib graph, correctly ranked.

---

## Phase 7 — WebGL Frontend: Renderer (Weeks 13–15)

**Goal:** A canvas that renders thousands of nodes and edges at 60fps.

### WebGL Architecture

You'll use two WebGL programs (shader pairs):

**Node Shader** — renders circles using a quad (two triangles) per node, with a circle mask in the fragment shader:
```glsl
// Vertex shader
attribute vec2 a_position;    // quad corner
attribute vec2 a_center;      // node center
attribute float a_radius;
attribute vec3 a_color;
varying vec2 v_uv;
varying vec3 v_color;

// Fragment shader — circle mask
float dist = length(v_uv);
if (dist > 1.0) discard;
gl_FragColor = vec4(v_color, 1.0 - smoothstep(0.9, 1.0, dist));
```

**Edge Shader** — renders lines as quads (two triangles per edge) with thickness:
```glsl
// Each edge = 4 vertices forming a rectangle
// Thickness = edge weight (normalized)
```

### Data Flow
```
Go Server  →  JSON (initial load)  →  TypeScript Graph Model
                                              ↓
                                    Pack into Float32Arrays
                                              ↓
                                    Upload to WebGL buffers (VBOs)
                                              ↓
                                    Draw call (instanced rendering)
```

Use **instanced rendering** (`gl.drawArraysInstanced`) — one draw call for all nodes, one for all edges. Do not loop in JavaScript.

### Tasks
- [ ] Set up WebGL context with error handling
- [ ] Implement `NodeRenderer`: build instanced VBO (center, radius, color per node), draw all nodes in one call
- [ ] Implement `EdgeRenderer`: build VBO (two endpoints, thickness per edge), draw all edges in one call
- [ ] Implement camera: pan (mouse drag → translate view matrix), zoom (scroll wheel → scale view matrix)
- [ ] Implement coordinate conversion: screen → world space for mouse interactions
- [ ] Implement hit testing: on click, find closest node within threshold (k-d tree in JS or GPU picking)
- [ ] Node color computation: lerp blue→red based on churn score from API
- [ ] Node size computation: map complexity to radius (sqrt scale to prevent huge nodes dominating)
- [ ] Edge thickness: map coupling weight to 1–5px range
- [ ] Render glow effect on "active" nodes (additive blending, second render pass)
- [ ] Performance test: render 10,000 nodes + 50,000 edges at 60fps. Verify in Chrome DevTools.

**Milestone:** Load Go stdlib graph from server. See all nodes and edges render at 60fps. Pan and zoom work smoothly.

---

## Phase 8 — Frontend: UI Layer (Weeks 16–17)

**Goal:** The interactive controls that make Cartographer usable.

### Components

**Details Panel** — appears on node click:
- File path, function name, line range
- Complexity score, churn score
- List of callers (in-edges) and callees (out-edges) as clickable links
- "Open in VS Code" button → `vscode://file/{absolute_path}:{line}` deep link

**Search Bar** — floating overlay:
- Debounced input → hits `/api/search`
- Results list with fuzzy match highlighting
- Press Enter or click result → camera flies to that node (smooth lerp animation)

**Camera Flight** — when navigating to a node:
- Smooth interpolation from current camera position to target node
- Ease-in-out curve over 600ms
- Node pulses briefly to indicate selection

**Convex Hull Districts** — module boundaries:
- Group nodes by their package/module prefix
- Compute convex hull of each group's (x, y) positions
- Render as a filled polygon with low opacity + outline
- Label the district with the package name

**Minimap** — small overview in corner:
- Orthographic render of entire graph at tiny scale
- Viewport indicator rectangle showing current view area
- Click minimap to jump camera

### Tasks
- [ ] Build details panel (DOM overlay positioned at node screen coords)
- [ ] Build search bar with debouncing and keyboard navigation
- [ ] Implement camera flight animation
- [ ] Implement convex hull computation (Graham scan algorithm — do not use a library)
- [ ] Render district polygons in WebGL (separate polygon renderer, additive blend)
- [ ] Render district labels (use a 2D Canvas overlay for text, composited over WebGL)
- [ ] Build minimap (second WebGL canvas, simplified render)
- [ ] Wire VS Code deep links

**Milestone:** Click a node → see its details. Search "ServeHTTP" → camera flies to the right node. Districts render with correct boundaries.

---

## Phase 9 — Git Time Slider (Weeks 18–19)

**Goal:** Drag a slider and watch the map morph to show how the codebase looked at any past commit.

### Technical Approach

For each historical commit:
1. The Go server calls `git checkout <commit> -- .` on a *copy* of the repo (never mutate the working tree)
2. Re-runs the C++ parser binary on the checked-out state
3. Stores the resulting graph as a snapshot

At slider time:
- Load two adjacent snapshots (before/after)
- For nodes present in both: lerp (x, y) positions
- For nodes only in "before": fade out (alpha → 0, scale → 0)
- For nodes only in "after": fade in (alpha 0→1, scale 0→1)
- Animate over 800ms

Pre-compute snapshots for the last N commits on startup (configurable, default 50).

### Tasks
- [ ] Go server: implement `git worktree` based snapshot generation (avoids touching working tree)
- [ ] Go server: run parser + layout on each snapshot, cache results to disk (`snapshots/<hash>.cgraph`)
- [ ] API: `GET /api/history` returns commit list with timestamps
- [ ] API: `GET /api/graph/snapshot?commit=<hash>` returns graph state for that commit
- [ ] Frontend: build time slider UI component (range input + commit labels)
- [ ] Frontend: implement graph morphing — diff two snapshots, compute per-node animation targets
- [ ] Frontend: drive WebGL buffer updates per animation frame
- [ ] Smooth playback: auto-play button that advances through commits at configurable speed

**Milestone:** Load a real repo. Drag the slider. Watch the map animate through 20 commits. New files appear, deleted files disappear, moved modules shift position.

---

## Phase 10 — Polish, Incremental Updates, Performance (Weeks 20–21)

### Incremental File Updates
- [ ] `fsnotify` watcher in Go server detects file saves
- [ ] Re-invoke parser binary on changed file only
- [ ] Diff new edges against existing edges, update adjacency lists
- [ ] Run 50 additional layout iterations around the changed node's neighborhood
- [ ] Push updated node positions to frontend via WebSocket
- [ ] Frontend animates repositioned nodes smoothly

### Performance Hardening
- [ ] Parser: benchmark and optimize hot paths (token classification, string interning)
- [ ] Layout: verify spatial grid optimization handles 50k+ node graphs
- [ ] Frontend: profile with Chrome GPU timeline, eliminate any per-frame allocations
- [ ] Server: add response caching with ETags for snapshot endpoints

### UX Polish
- [ ] Add loading progress bar during initial graph load
- [ ] Add "reset view" button (fit all nodes in viewport)
- [ ] Add keyboard shortcuts: `/` to focus search, `Escape` to deselect, `G` to reset camera
- [ ] Add a legend overlay explaining node size, color, edge thickness
- [ ] Error states: what shows if the parser fails on a file? (Show broken node in gray)
- [ ] Add TypeScript support to parser (Phase 11)

**Milestone:** Cartographer can be opened on any Go codebase. The full experience — parse, layout, render, search, click, git history — works end-to-end without errors.

---

## Phase 11 — TypeScript Parser (Weeks 22–23)

Add TypeScript language support to the C++ parser.

TypeScript is harder than Go because of:
- ASI (automatic semicolon insertion) — must handle missing semicolons
- Template literals — complex multi-line strings
- Generics — `<T extends X>` can look like comparison operators
- Arrow functions — many syntactic forms for function definitions
- Decorators — `@` prefix on classes and methods

### Tasks
- [ ] Add TypeScript keyword set to lexer
- [ ] Add TypeScript-specific token types: `ARROW`, `TEMPLATE_START`, `TEMPLATE_END`, `DECORATOR`
- [ ] Implement TypeScript function/method/arrow-function definition detection
- [ ] Handle `import`/`export` statements for dependency edges
- [ ] Handle class declarations and method extraction
- [ ] Test on `typescript/lib/typescript.js` (the TypeScript compiler itself — extreme stress test)

**Milestone:** Run Cartographer on the TypeScript compiler's own source. Get a valid graph with no crashes.

---

## Phase 12 — Stretch Features (Weeks 24+)

These are ordered by value-to-effort ratio:

### 12a — Shareable HTML Export
- Frontend generates a self-contained HTML file
- Embeds all node/edge data as JSON in a `<script>` tag
- Includes minified renderer inline
- Anyone can open it — no server required

### 12b — VS Code Extension
- Language Server Protocol integration
- Map panel embedded in VS Code sidebar
- Syncs cursor position to highlight active node in map
- Clicking map node moves editor cursor to that function

### 12c — Team Ownership Layer
- Parse `git blame` to assign each line to an author
- Map file ownership to engineers by majority blame
- Color districts by owning engineer
- Toggle with keyboard shortcut

### 12d — Vulnerability Overlay
- Read `go.sum` / `package-lock.json` for dependency versions
- Cross-reference against OSV (Open Source Vulnerabilities) database API
- Color nodes red if their dependency has known CVEs
- Click node to see CVE details

---

## Version Targets

| Version | Contents |
|---|---|
| v0.1 | Parser + binary format working (Phases 1–3) |
| v0.2 | Layout engine + query server (Phases 4–6) |
| v0.3 | WebGL renderer + basic UI (Phases 7–8) |
| v0.4 | Git time slider (Phase 9) |
| v1.0 | Polished, TypeScript support, incremental updates (Phases 10–11) |
| v2.0 | Stretch features (Phase 12) |