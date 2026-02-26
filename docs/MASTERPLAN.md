# 🧠 Cartographer — MASTERPLAN

This document is the **single source of truth** for all architectural decisions, data flow, algorithm choices, and design rationale. Read this before touching any code.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [System Overview](#2-system-overview)
3. [Component 1: C++ Parser Engine](#3-component-1-cpp-parser-engine)
4. [Component 2: Go Layout + Query Engine](#4-component-2-go-layout--query-engine)
5. [Component 3: TypeScript WebGL Frontend](#5-component-3-typescript-webgl-frontend)
6. [Binary Graph Format (.cgraph)](#6-binary-graph-format-cgraph)
7. [Data Flow: End to End](#7-data-flow-end-to-end)
8. [Algorithm Deep Dives](#8-algorithm-deep-dives)
9. [Inter-Process Communication](#9-inter-process-communication)
10. [State Management](#10-state-management)
11. [Incremental Update Architecture](#11-incremental-update-architecture)
12. [Git History Feature Architecture](#12-git-history-feature-architecture)
13. [Performance Targets](#13-performance-targets)
14. [Testing Strategy](#14-testing-strategy)
15. [Key Design Decisions & Rationale](#15-key-design-decisions--rationale)

---

## 1. Problem Statement

Code is a graph. Developers read it linearly. This mismatch means:
- Onboarding to a large codebase takes weeks
- Hotspots and problematic coupling are invisible until they cause bugs
- The "mental map" senior engineers hold is never externalized or shared

Cartographer solves this by **extracting the implicit graph structure of code and making it spatially navigable**.

---

## 2. System Overview

```
                        ┌───────────────────────────────────────────────────┐
                        │                  USER'S REPOSITORY                │
                        └─────────────────────────┬─────────────────────────┘
                                                   │  file system path
                                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                        COMPONENT 1: C++ PARSER ENGINE                        │
│                                                                              │
│   Source files → Lexer → Token Stream → Parser → AST Fragment → Graph       │
│                                                         Emitter → .cgraph   │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │  .cgraph binary file
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                     COMPONENT 2: GO LAYOUT + QUERY ENGINE                    │
│                                                                              │
│   .cgraph → Graph Loader → Fruchterman-Reingold → (x,y) per node            │
│                                    ↓                                         │
│                            Query Layer (BFS, radius, search)                 │
│                                    ↓                                         │
│                            HTTP Server + WebSocket                           │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │  JSON over HTTP / binary over WS
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    COMPONENT 3: TYPESCRIPT WEBGL FRONTEND                    │
│                                                                              │
│   HTTP Client → Graph Model → Float32Array VBOs → WebGL Draw Calls          │
│                                    ↓                                         │
│                          UI Layer (DOM overlays, search, panels)             │
└──────────────────────────────────────────────────────────────────────────────┘
```

The three components communicate only through:
- **C++ → Go**: `.cgraph` binary file (written by parser, read by engine at startup)
- **Go → TypeScript**: JSON REST API + WebSocket for live updates

---

## 3. Component 1: C++ Parser Engine

### Responsibilities
- Lex and partially parse source files
- Extract function/method definitions, call expressions, imports
- Compute cyclomatic complexity per function
- Build an in-memory call graph
- Serialize to `.cgraph` binary format

### Non-Responsibilities
- The parser is **NOT** a full compiler front-end
- It does **NOT** perform type resolution or symbol binding
- It does **NOT** need to parse every language construct — only those relevant to graph extraction

### Architecture

```
cartographer-parser [REPO_PATH] [OPTIONS]
│
├── FileWalker — recursively finds source files by extension
│
├── For each source file:
│   ├── FileReader — reads bytes into buffer
│   ├── Lexer — converts bytes → token stream
│   ├── Parser — converts tokens → Graph mutations
│   │   ├── parseFunctionDecl()   → add function node
│   │   ├── parseMethodDecl()     → add method node
│   │   ├── parseImportDecl()     → add import edge
│   │   ├── parseFunctionBody()   → scan for calls, count complexity
│   │   └── parseCallExpr()       → add call edge
│   └── Graph.AddNode() / Graph.AddEdge()
│
├── CrossReferencePass — resolve cross-package call edges
│
└── Emitter — serialize Graph → .cgraph file
```

### Lexer Design

The lexer is a state machine over the input byte stream.

**State transitions:**
```
INITIAL →  letter/_ → IDENT
        →  digit    → NUMBER
        →  '"'      → STRING
        →  '`'      → RAW_STRING  (Go specific)
        →  '/'      → MAYBE_COMMENT
        →  '('      → emit LPAREN, stay INITIAL
        ... (all single-char operators)

IDENT   →  letter/digit/_ → IDENT
        →  other          → emit IDENT or KEYWORD, return char, INITIAL

MAYBE_COMMENT → '/' → LINE_COMMENT
              → '*' → BLOCK_COMMENT
              → other → emit SLASH, return char, INITIAL
```

**Token struct:**
```cpp
struct Token {
    TokenType type;
    std::string_view value;  // points into source buffer (zero-copy)
    uint32_t line;
    uint32_t column;
    uint32_t file_id;
};
```

Use `std::string_view` to avoid copying token text — the entire source buffer stays in memory and tokens point into it.

### Parser Design

The parser is a **single-pass recursive descent** parser that tracks brace depth to locate function bodies. It does not build a full AST — it mutates the graph directly as it parses.

Key parsing technique — **brace depth scanning**:
```cpp
// When we encounter a function body opening brace:
int depth = 1;
while (depth > 0) {
    Token t = next();
    if (t == LBRACE) depth++;
    if (t == RBRACE) depth--;
    // While scanning body, identify call expressions and branch keywords
    if (t == IDENT && peek() == LPAREN) {
        graph.addCallEdge(currentFunction, t.value);
    }
    if (isComplexityKeyword(t)) {
        currentFunction.complexity++;
    }
}
```

### Complexity Keywords by Language

**Go:** `if`, `else if`, `for`, `range`, `switch`, `case`, `select`, `&&`, `||`, `go` (goroutine launch)

**TypeScript:** `if`, `else if`, `for`, `while`, `do`, `switch`, `case`, `catch`, `&&`, `||`, `??`, ternary `?`

### Cross-Reference Pass

After parsing all files, many call edges target functions in other files. The cross-reference pass:

1. Builds a map: `qualified_name → NodeID`
2. For each unresolved edge `(caller, "someFunc")`:
   - Check if `"someFunc"` is imported (look in the file's import list)
   - If yes, resolve the import path to a package, find the function in that package
   - If found, replace the edge with the resolved `NodeID`
   - If not, keep as an "external" edge (may point outside the repo)

---

## 4. Component 2: Go Layout + Query Engine

### Responsibilities
- Load and own the graph data structure in memory
- Compute 2D spatial positions for all nodes (Fruchterman-Reingold)
- Serve the HTTP API consumed by the frontend
- Handle WebSocket connections for live updates
- Parse git log to compute churn scores
- Manage snapshot generation for git history feature

### Package Structure

```
engine/
├── main.go                # CLI entry point, wires everything together
├── graph/
│   ├── graph.go           # Graph, Node, Edge types
│   ├── loader.go          # .cgraph binary reader
│   └── index.go           # KD-tree and adjacency list indexes
├── layout/
│   ├── fruchterman.go     # Force-directed layout implementation
│   ├── grid.go            # Spatial grid for O(n log n) repulsion
│   └── normalize.go       # Scale positions to output coordinate space
├── query/
│   ├── spatial.go         # Radius queries (KD-tree search)
│   ├── path.go            # BFS shortest path
│   └── search.go          # Fuzzy text search (trigram index)
├── git/
│   ├── log.go             # git log parser → churn scores
│   └── snapshot.go        # Worktree-based snapshot generator
├── server/
│   ├── server.go          # HTTP server setup, route registration
│   ├── handlers.go        # Handler functions for each endpoint
│   └── websocket.go       # WebSocket hub, broadcast, client management
└── watcher/
    └── watcher.go         # fsnotify watcher → incremental parse trigger
```

### Graph Data Structure

```go
type Node struct {
    ID         uint32
    Name       string
    File       string
    LineStart  uint32
    LineEnd    uint32
    Complexity uint16
    Churn      uint16
    Type       NodeType  // File | Function | Method
    X, Y       float64   // Set after layout
}

type Edge struct {
    Src    uint32
    Dst    uint32
    Type   EdgeType  // Call | Import
    Weight uint16
}

type Graph struct {
    Nodes    []Node
    Edges    []Edge
    OutEdges [][]uint32  // adjacency list: OutEdges[nodeID] = []dst nodeIDs
    InEdges  [][]uint32  // reverse adjacency list
    NameIdx  map[string]uint32  // name → node ID (for search + cross-reference)
    FileIdx  map[string][]uint32  // file path → node IDs in that file
}
```

---

## 5. Component 3: TypeScript WebGL Frontend

### Responsibilities
- Fetch graph data from Go server at startup
- Maintain a client-side graph model
- Render nodes and edges using WebGL (60fps target)
- Handle user interactions (pan, zoom, click, hover, search)
- Animate camera, node updates, and git history transitions
- Render district boundaries as convex hulls
- Provide UI controls (search, details panel, time slider)

### Module Structure

```
frontend/src/
├── main.ts                # Entry point — wires all modules
├── api/
│   ├── client.ts          # HTTP client for Go server REST API
│   └── websocket.ts       # WebSocket connection management
├── graph/
│   ├── model.ts           # Client-side Graph, Node, Edge types
│   └── diff.ts            # Diff two graph snapshots for animation
├── renderer/
│   ├── context.ts         # WebGL context creation + capabilities check
│   ├── shaders.ts         # GLSL shader source strings + compilation
│   ├── nodeRenderer.ts    # Instanced node rendering
│   ├── edgeRenderer.ts    # Edge line rendering
│   ├── districtRenderer.ts # Convex hull polygon rendering
│   └── glowRenderer.ts    # Additive glow pass for active nodes
├── camera/
│   ├── camera.ts          # View/projection matrix, pan/zoom state
│   └── flight.ts          # Animated camera transitions
├── interaction/
│   ├── picker.ts          # Mouse → node hit testing
│   ├── drag.ts            # Pan gesture handling
│   └── zoom.ts            # Scroll zoom handling
├── ui/
│   ├── search.ts          # Search bar component
│   ├── details.ts         # Node details panel
│   ├── minimap.ts         # Minimap overlay
│   ├── slider.ts          # Git history time slider
│   └── legend.ts          # Color/size legend overlay
└── utils/
    ├── convexHull.ts      # Graham scan convex hull algorithm
    ├── kdtree.ts          # KD-tree for client-side hit testing
    └── easing.ts          # Animation easing functions
```

### WebGL Rendering Architecture

The renderer uses **instanced rendering** — one draw call for all nodes, one for all edges.

**Node VBO layout (per instance):**
```
[cx: f32][cy: f32][radius: f32][r: f32][g: f32][b: f32][alpha: f32]
```

**Edge VBO layout (per edge, 4 vertices):**
```
Each edge expands to a quad:
vertex 0: (ax + n*w, ay + n*w)
vertex 1: (ax - n*w, ay - n*w)
vertex 2: (bx + n*w, by + n*w)
vertex 3: (bx - n*w, by - n*w)
where (a,b) = endpoints, n = perpendicular normal, w = half-width
```

**Render loop:**
```
requestAnimationFrame(renderFrame)
  │
  ├── Update camera matrix if animating
  ├── Update node VBO if graph changed (WebSocket update or time-slider)
  │
  ├── glClear()
  ├── edgeRenderer.draw(camera)      — gl.drawArrays, all edges
  ├── nodeRenderer.draw(camera)      — gl.drawArraysInstanced, all nodes
  ├── districtRenderer.draw(camera)  — gl.drawArrays, convex hull polygons
  ├── glowRenderer.draw(camera)      — additive blend pass, active nodes only
  │
  └── requestAnimationFrame(renderFrame)
```

**2D Canvas overlay (separate element, composited by browser):**
- District labels (text)
- Search bar, details panel, time slider (DOM elements, CSS positioned)

---

## 6. Binary Graph Format (.cgraph)

The `.cgraph` format is designed for:
- Fast sequential write (parser writes once)
- Fast sequential read (engine reads once at startup)
- Compact size (string table deduplication, fixed-size records)

### Full Binary Layout

```
Offset  Size  Field
────────────────────────────────────────────────────────
HEADER (16 bytes)
0       4     magic number: 0x43475048 ("CGPH" big-endian)
4       2     format version: 0x0001
6       4     node_count (uint32 little-endian)
10      4     edge_count (uint32 little-endian)
14      2     flags (reserved, write 0x0000)

STRING TABLE
16      4     str_table_byte_length (uint32)
20      N     string data: null-terminated UTF-8 strings, concatenated
              String at offset 0 is always the empty string ""

NODE TABLE  (aligned to 4-byte boundary after string table)
            node_count × 32 bytes each
  +0   4    name_str_offset (uint32, byte offset into string table)
  +4   4    file_str_offset (uint32)
  +8   4    line_start (uint32, 1-indexed)
  +12  4    line_end (uint32, 1-indexed, inclusive)
  +16  2    complexity (uint16, cyclomatic complexity)
  +18  2    churn (uint16, written as 0 by parser, filled by Go engine)
  +20  1    node_type (uint8: 0=file, 1=function, 2=method)
  +21  11   padding (zero-filled)

EDGE TABLE  (immediately after node table)
            edge_count × 12 bytes each
  +0   4    src_node_id (uint32, index into node table)
  +4   4    dst_node_id (uint32)
  +8   1    edge_type (uint8: 0=call, 1=import)
  +9   2    weight (uint16, call frequency; 1 if unknown)
  +11  1    padding

POSITIONS TABLE  (optional section, written by Go engine after layout)
            present if flags bit 0 = 1
            node_count × 16 bytes each
  +0   8    x (float64, layout coordinate)
  +8   8    y (float64, layout coordinate)
```

**Total size estimate for Go stdlib (~1200 files, ~15000 functions, ~80000 edges):**
- Header: 16 bytes
- String table: ~500KB (file paths + function names, heavily deduplicated)
- Node table: 15000 × 32 = 480KB
- Edge table: 80000 × 12 = 960KB
- **Total: ~2MB** — fast to read, reasonable to cache

---

## 7. Data Flow: End to End

### Initial Load

```
User runs: cartographer-parser /my/repo --out graph.cgraph
           cartographer-engine --graph graph.cgraph --port 8080
           (browser opens localhost:5173)

1. Parser walks /my/repo, finds all .go files
2. Lexes + parses each file → Graph object in memory
3. Cross-reference pass resolves inter-file calls
4. Emitter writes graph.cgraph

5. Engine reads graph.cgraph → Go Graph struct in memory
6. Engine reads `git log` for the repo → fills churn scores on each file node
7. Engine runs Fruchterman-Reingold → each node gets (x, y)
8. Engine starts HTTP server on :8080

9. Browser loads frontend JS
10. Frontend calls GET /api/nodes (paginated or full — TBD by graph size)
11. Frontend calls GET /api/graph/stats
12. Frontend builds client-side Graph model
13. Frontend packs node data into Float32Arrays, uploads to WebGL VBOs
14. First frame renders
15. Frontend opens WebSocket connection to /ws/watch for live updates
```

### File Change Event

```
Developer saves a file →
  fsnotify fires in Go engine →
    Engine calls: cartographer-parser [changed_file] --out delta.cgraph →
    Engine reads delta.cgraph →
    Engine diffs new edges vs old edges →
    Engine runs 50 layout iterations on affected subgraph →
    Engine pushes {type: "node_update", nodes: [...]} over WebSocket →
      Frontend receives update →
      Frontend lerp-animates repositioned nodes over 400ms →
      Developer sees the map shift in response to their edit
```

---

## 8. Algorithm Deep Dives

### Fruchterman-Reingold Force-Directed Layout

**Parameters:**
```
W, H      = canvas width and height (e.g., 10000 × 10000 units)
area      = W × H
k         = C × sqrt(area / |V|)   where C ≈ 1.0 (tuning constant)
t_initial = W / 10                 (initial temperature)
max_iter  = 1000
```

**Per-iteration pseudocode:**
```
for each iteration:
    // Calculate repulsive forces (all pairs — use grid optimization)
    for each node v:
        v.disp = (0, 0)
    for each pair (u, v) where u ≠ v:
        delta = v.pos - u.pos
        dist  = max(|delta|, 0.01)    // avoid division by zero
        force = k² / dist
        v.disp += (delta / dist) * force
        u.disp -= (delta / dist) * force

    // Calculate attractive forces (only along edges)
    for each edge (u, v):
        delta = v.pos - u.pos
        dist  = max(|delta|, 0.01)
        force = dist² / k
        v.disp -= (delta / dist) * force
        u.disp += (delta / dist) * force

    // Apply displacements, clamped by temperature
    for each node v:
        disp_len = max(|v.disp|, 0.01)
        v.pos += (v.disp / disp_len) * min(disp_len, t)
        v.pos.x = clamp(v.pos.x, 0, W)
        v.pos.y = clamp(v.pos.y, 0, H)

    // Cool
    t = t × (1 - iteration / max_iter)
```

**Grid optimization for O(n log n) repulsion:**

Divide the canvas into a grid of cells, each of size `3k × 3k`. When computing repulsive forces for node v, only consider nodes in the same or adjacent cells (within a 3×3 neighborhood). Nodes farther than `3k` contribute negligible force.

```go
type Grid struct {
    cells    map[CellCoord][]uint32  // cell → list of node IDs
    cellSize float64
}

func (g *Grid) nearbyNodes(pos Vec2) []uint32 {
    cx, cy := int(pos.X/g.cellSize), int(pos.Y/g.cellSize)
    var result []uint32
    for dx := -1; dx <= 1; dx++ {
        for dy := -1; dy <= 1; dy++ {
            result = append(result, g.cells[{cx+dx, cy+dy}]...)
        }
    }
    return result
}
```

Rebuild the grid at the start of each iteration.

### BFS Shortest Path

Used for `/api/path?from=A&to=B`. Returns the shortest call path between two functions.

```go
func BFS(graph *Graph, srcID, dstID uint32) []uint32 {
    queue := []uint32{srcID}
    visited := make(map[uint32]uint32)  // node → predecessor
    visited[srcID] = srcID

    for len(queue) > 0 {
        cur := queue[0]
        queue = queue[1:]
        if cur == dstID {
            return reconstructPath(visited, srcID, dstID)
        }
        for _, neighbor := range graph.OutEdges[cur] {
            if _, seen := visited[neighbor]; !seen {
                visited[neighbor] = cur
                queue = append(queue, neighbor)
            }
        }
    }
    return nil  // no path
}
```

### Convex Hull (Graham Scan)

Used to draw district boundaries. Graham scan is O(n log n).

```typescript
function convexHull(points: Vec2[]): Vec2[] {
    if (points.length < 3) return points;
    
    // Find pivot: lowest y, then leftmost x
    const pivot = points.reduce((a, b) => a.y < b.y || (a.y === b.y && a.x < b.x) ? a : b);
    
    // Sort by polar angle from pivot
    const sorted = points
        .filter(p => p !== pivot)
        .sort((a, b) => {
            const angleA = Math.atan2(a.y - pivot.y, a.x - pivot.x);
            const angleB = Math.atan2(b.y - pivot.y, b.x - pivot.x);
            return angleA - angleB;
        });
    
    // Graham scan
    const hull = [pivot, sorted[0]];
    for (let i = 1; i < sorted.length; i++) {
        while (hull.length > 1 && cross(hull[hull.length-2], hull[hull.length-1], sorted[i]) <= 0) {
            hull.pop();
        }
        hull.push(sorted[i]);
    }
    return hull;
}

function cross(O: Vec2, A: Vec2, B: Vec2): number {
    return (A.x - O.x) * (B.y - O.y) - (A.y - O.y) * (B.x - O.x);
}
```

---

## 9. Inter-Process Communication

### Parser → Engine: Binary File

The C++ parser is invoked as a **subprocess** by the Go engine when needed (initial parse, file updates, snapshot generation). The engine calls:

```go
cmd := exec.Command("cartographer-parser", repoPath, "--out", outputPath)
err := cmd.Run()
```

This keeps the two components completely decoupled. The parser can be replaced or updated without touching the engine.

For incremental updates, the engine passes `--files file1.go,file2.go` to re-parse only specific files.

### Engine → Frontend: REST + WebSocket

REST for read-heavy, cacheable data (graph stats, node lists, snapshots). WebSocket for push-based real-time updates (file changes, layout updates).

WebSocket message format:
```json
{
  "type": "node_update",
  "payload": {
    "nodes": [
      { "id": 42, "x": 1234.5, "y": 5678.9, "complexity": 15, "churn": 8 }
    ],
    "edges_added": [...],
    "edges_removed": [...]
  }
}
```

---

## 10. State Management

### Go Engine State

The engine holds one canonical `*Graph` in memory. All HTTP handlers read from it. The watcher goroutine is the only writer. Reads use `sync.RWMutex`:

```go
type Engine struct {
    graph *graph.Graph
    mu    sync.RWMutex
    hub   *server.WebSocketHub
}

// Read path (all handlers):
func (e *Engine) GetNode(id uint32) *graph.Node {
    e.mu.RLock()
    defer e.mu.RUnlock()
    return &e.graph.Nodes[id]
}

// Write path (watcher only):
func (e *Engine) ApplyDelta(delta *graph.Delta) {
    e.mu.Lock()
    defer e.mu.Unlock()
    e.graph.ApplyDelta(delta)
    e.hub.Broadcast(delta.ToWebSocketMessage())
}
```

### Frontend State

The frontend holds a single `GraphModel` object — a direct mirror of the data from the server. When a WebSocket update arrives, the model is diffed and VBOs are surgically updated (don't re-upload the entire buffer for a single node change):

```typescript
// Only update the changed node's slice in the VBO:
gl.bindBuffer(gl.ARRAY_BUFFER, nodeVBO);
const offset = nodeID * NODE_INSTANCE_STRIDE;
gl.bufferSubData(gl.ARRAY_BUFFER, offset, newNodeData);
```

---

## 11. Incremental Update Architecture

```
fsnotify.Event (file changed)
│
├── Debounce (100ms — batch rapid saves)
│
├── Invoke parser subprocess: cartographer-parser --files <changedFile> --out delta.cgraph
│
├── Read delta.cgraph → DeltaGraph{nodes_new, nodes_updated, edges_added, edges_removed}
│
├── Apply delta to main Graph:
│   ├── Update/add Node structs
│   ├── Add/remove Edge structs
│   └── Rebuild adjacency list slices for affected nodes
│
├── Run layout refinement:
│   ├── Fix affected nodes at their current positions
│   ├── Run 50 iterations of F-R on the local neighborhood (nodes within 2 hops of changed nodes)
│   └── Update (x, y) for repositioned nodes
│
└── Broadcast WebSocket message with updated positions + edge changes
```

**Why neighborhood-only layout?** Running full Fruchterman-Reingold on 15,000 nodes takes ~3 seconds. A file change affects maybe 50–200 nodes. Running layout on the local subgraph converges in milliseconds and produces correct results because distant nodes have negligible force interactions anyway.

---

## 12. Git History Feature Architecture

### Snapshot Generation

At engine startup, generate snapshots for the last N commits (default 50):

```go
func GenerateSnapshots(repoPath string, n int) error {
    commits, _ := parseGitLog(repoPath, n)
    
    for _, commit := range commits {
        snapshotPath := fmt.Sprintf("snapshots/%s.cgraph", commit.Hash)
        if fileExists(snapshotPath) {
            continue  // already generated
        }
        
        // Use git worktree to avoid touching working directory
        worktreePath := fmt.Sprintf("/tmp/cartographer-wt-%s", commit.Hash[:8])
        exec.Command("git", "-C", repoPath, "worktree", "add",
            "--detach", worktreePath, commit.Hash).Run()
        
        // Parse the worktree
        exec.Command("cartographer-parser", worktreePath,
            "--out", snapshotPath).Run()
        
        // Clean up worktree
        exec.Command("git", "-C", repoPath, "worktree", "remove",
            worktreePath, "--force").Run()
        
        // Run layout on snapshot
        runLayoutForSnapshot(snapshotPath)
    }
}
```

Snapshots are cached to disk — regeneration only happens when new commits arrive.

### Frontend Morphing

When the user drags the time slider from commit A to commit B:

```typescript
const morphDuration = 800;  // ms
const snapshotA = await api.getSnapshot(commitA);
const snapshotB = await api.getSnapshot(commitB);

const diff = diffSnapshots(snapshotA, snapshotB);
// diff.common: nodes present in both → lerp position
// diff.removed: nodes only in A → fade out (alpha → 0, scale → 0)
// diff.added: nodes only in B → fade in (alpha 0→1, scale 0→1)

animateMorph(diff, morphDuration);
```

---

## 13. Performance Targets

| Operation | Target | How |
|---|---|---|
| Parse Go stdlib (1200 files) | < 10 seconds | C++, parallel file parsing with thread pool |
| Fruchterman-Reingold (15k nodes, 1000 iter) | < 30 seconds | Spatial grid, goroutines per iteration |
| HTTP API response time (any query) | < 50ms | In-memory indexes, no DB |
| WebGL render frame (10k nodes, 50k edges) | < 16ms (60fps) | Instanced rendering, one draw call per primitive type |
| Incremental file update (one file changed) | < 500ms | Subprocess parser + local layout only |
| Snapshot generation per commit | < 15 seconds | Cached to disk, background generation |

---

## 14. Testing Strategy

### C++ Parser

- **Unit tests** per token type: verify lexer output for crafted inputs
- **Fixture tests**: parse 20 real `.go` files from stdlib, compare extracted function list against golden output files
- **Stress test**: parse entire Go stdlib without crashing. Check node/edge count is within expected range.
- **Fuzz test** (libFuzzer): feed random bytes to lexer, ensure no undefined behavior

### Go Engine

- **Unit tests** for each query type with a small synthetic graph
- **Layout test**: run F-R on a known graph (e.g., a grid), verify connected nodes are closer than disconnected nodes
- **BFS test**: hand-craft a graph, verify shortest paths are correct
- **Integration test**: start the full server, hit all endpoints, assert response schema
- **Benchmark** (`go test -bench`): measure query latency, layout time, binary load time

### TypeScript Frontend

- **Unit tests** (Vitest): convex hull algorithm, camera matrix math, graph diff logic
- **Visual regression tests**: render a fixed synthetic graph to a canvas, compare pixel output (use Playwright screenshot comparison)
- **E2E test** (Playwright): load the frontend against a running engine, click nodes, use search, verify details panel shows correct data

---

## 15. Key Design Decisions & Rationale

### Why hand-written parser instead of tree-sitter?

**Decision:** Write a recursive descent parser from scratch.

**Rationale:** This is the architecturally interesting part. Tree-sitter would reduce Cartographer to a data pipeline script. A hand-written parser demonstrates compiler knowledge, handles our partial-parse requirements exactly, produces faster code (no FFI overhead), and is the primary technical talking point in interviews.

**Tradeoff:** More work, potential for edge-case bugs in language grammar. Mitigated by fixture + stress tests.

### Why C++ for the parser?

**Decision:** C++ for the parser, Go for the engine.

**Rationale:** The parser runs on every file at startup and during incremental updates. Performance matters. C++ gives full control over memory layout (token struct fits in a cache line), string_view avoids copies, and the parser is compute-bound with no async needs. Go's GC and runtime overhead would slow the parser with no compensating benefit.

**Tradeoff:** Three-language project. Mitigated by clean interface (binary file + subprocess invocation).

### Why a custom binary format instead of JSON?

**Decision:** `.cgraph` binary format.

**Rationale:** The Go stdlib graph is ~2MB in binary. In JSON it would be ~15–20MB with field name overhead. Binary parsing is 10–50× faster. The format is designed once and barely changes — it's not a user-facing API. This is also a technically interesting component that demonstrates systems knowledge.

**Tradeoff:** Not human-readable. Mitigated by providing a `cgraph-dump` CLI tool that pretty-prints a `.cgraph` file.

### Why raw WebGL instead of D3 or Sigma.js?

**Decision:** Raw WebGL (possibly with minimal Three.js for camera only).

**Rationale:** D3 uses SVG — it will not render 10,000 nodes at 60fps. Sigma.js would work but removes all the technically interesting rendering work. Raw WebGL with instanced rendering is the only approach that achieves the performance targets and demonstrates graphics programming knowledge.

**Tradeoff:** More frontend code. Significantly harder rendering work. This is intentional — it's the showcase.

### Why force-directed layout instead of hierarchical?

**Decision:** Fruchterman-Reingold force-directed layout.

**Rationale:** Hierarchical layouts (like Sugiyama) assume a DAG and produce a tree-like diagram. Code call graphs are not trees — they're dense cyclic graphs. Force-directed layout naturally handles cycles and produces emergent clustering where coupling is high. The spatial proximity = coupling property is the core value proposition of Cartographer.

**Tradeoff:** Non-deterministic (random initial positions), computationally expensive. Mitigated by fixed random seed for reproducibility and the spatial grid optimization for performance.

### Why Go for the engine instead of C++ or Node.js?

**Decision:** Go for the layout engine + HTTP server.

**Rationale:** Go's goroutines make it easy to parallelize the force simulation across nodes. The HTTP server and WebSocket handling are straightforward in Go's standard library. Go's memory model is simpler than C++'s for long-lived server code. Node.js would be single-threaded and couldn't parallelize layout computation.

**Tradeoff:** Another language in the stack. The C++ → Go boundary is clean (binary file + subprocess) and the Go → TypeScript boundary is standard HTTP, so the multi-language complexity is managed.