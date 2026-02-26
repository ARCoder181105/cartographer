# 🏗️ Cartographer — Architecture Reference

This document is a companion to MASTERPLAN.md, focused on the exact file structure, interface contracts, and implementation patterns for each component.

---

## Directory Layout (Full)

```
cartographer/
│
├── Makefile                    # Root build: `make all`, `make test`, `make clean`
├── README.md                   # Project overview (root level, rendered by GitHub)
│
├── docs/                       # All project documentation
│   ├── ROADMAP.md              # Phased build plan with milestones
│   ├── MASTERPLAN.md           # Architecture decisions + data flow
│   ├── ARCHITECTURE.md         # This file
│   ├── ALGORITHMS.md           # Algorithm pseudocode + analysis
│   ├── BINARY_FORMAT.md        # .cgraph format spec (added in Phase 3)
│   ├── PARSER_GRAMMAR.md       # Grammar reference (added in Phase 1)
│   └── API.md                  # HTTP API reference (added in Phase 6)
│
├── parser/                     # C++ Parser Engine
│   ├── CMakeLists.txt
│   ├── src/
│   │   ├── main.cpp            # CLI entry point
│   │   ├── lexer/
│   │   │   ├── token.hpp       # Token enum + Token struct
│   │   │   ├── token.cpp
│   │   │   ├── lexer.hpp       # Lexer class declaration
│   │   │   └── lexer.cpp       # Lexer implementation
│   │   ├── parser/
│   │   │   ├── parser.hpp      # Parser class declaration
│   │   │   ├── parser.cpp      # Parser implementation
│   │   │   └── complexity.hpp  # Complexity counter utility
│   │   ├── graph/
│   │   │   ├── graph.hpp       # Node, Edge, Graph types
│   │   │   ├── graph.cpp
│   │   │   └── crossref.cpp    # Cross-reference resolution pass
│   │   ├── emitter/
│   │   │   ├── emitter.hpp     # Binary emitter class
│   │   │   └── emitter.cpp
│   │   └── walker/
│   │       ├── walker.hpp      # File system walker
│   │       └── walker.cpp
│   └── tests/
│       ├── fixtures/           # Real .go files for fixture tests
│       ├── lexer_test.cpp
│       ├── parser_test.cpp
│       └── emitter_test.cpp
│
├── engine/                     # Go Layout + Query Engine
│   ├── go.mod
│   ├── go.sum
│   ├── main.go
│   ├── graph/
│   │   ├── graph.go            # Node, Edge, Graph types
│   │   ├── loader.go           # .cgraph binary reader
│   │   ├── delta.go            # Delta/diff types for incremental updates
│   │   └── index.go            # KD-tree + adjacency list construction
│   ├── layout/
│   │   ├── fruchterman.go      # Main F-R algorithm
│   │   ├── grid.go             # Spatial grid for O(n log n) repulsion
│   │   └── normalize.go        # Post-layout coordinate normalization
│   ├── query/
│   │   ├── spatial.go          # Radius queries using KD-tree
│   │   ├── path.go             # BFS / Dijkstra path finding
│   │   └── search.go           # Trigram-based fuzzy text search
│   ├── git/
│   │   ├── log.go              # `git log` parser → churn scores
│   │   └── snapshot.go         # Git worktree snapshot manager
│   ├── server/
│   │   ├── server.go           # HTTP server + middleware setup
│   │   ├── handlers.go         # HTTP handler functions
│   │   ├── websocket.go        # WebSocket hub + client management
│   │   └── response_types.go   # JSON response struct definitions
│   └── watcher/
│       └── watcher.go          # fsnotify watcher + debouncer
│
└── frontend/                   # TypeScript + WebGL Frontend
    ├── package.json
    ├── tsconfig.json
    ├── vite.config.ts
    ├── index.html
    └── src/
        ├── main.ts
        ├── api/
        │   ├── client.ts       # Typed HTTP client
        │   ├── types.ts        # API response types (mirrors Go response_types.go)
        │   └── websocket.ts    # WebSocket connection + message handling
        ├── graph/
        │   ├── model.ts        # GraphModel, NodeModel, EdgeModel
        │   └── diff.ts         # Snapshot diffing for morph animation
        ├── renderer/
        │   ├── context.ts      # WebGL2 context + extension setup
        │   ├── shaders.ts      # GLSL source strings + shader compilation
        │   ├── program.ts      # ShaderProgram wrapper
        │   ├── nodeRenderer.ts # Instanced circle rendering
        │   ├── edgeRenderer.ts # Line quad rendering
        │   ├── districtRenderer.ts # Convex hull polygon rendering
        │   └── glowRenderer.ts # Additive blend glow pass
        ├── camera/
        │   ├── camera.ts       # Camera state (pan, zoom, projection matrix)
        │   └── flight.ts       # Animated camera target system
        ├── interaction/
        │   ├── picker.ts       # World-space node hit testing
        │   ├── pan.ts          # Mouse drag → camera pan
        │   └── zoom.ts         # Scroll wheel → camera zoom
        ├── ui/
        │   ├── search.ts       # Search bar + results dropdown
        │   ├── details.ts      # Node details side panel
        │   ├── slider.ts       # Git history time slider
        │   ├── minimap.ts      # Minimap overlay (separate WebGL canvas)
        │   └── legend.ts       # Color/size encoding legend
        └── utils/
            ├── convexHull.ts   # Graham scan
            ├── kdtree.ts       # 2D KD-tree (client-side hit testing)
            ├── easing.ts       # Animation curves
            └── math.ts         # Vec2, Mat3 mini math library
```

---

## Interface Contracts

### Parser CLI Interface

```
SYNOPSIS
    cartographer-parser [OPTIONS] REPO_PATH

OPTIONS
    --out PATH          Output .cgraph file path (default: ./graph.cgraph)
    --lang LANG         Language filter: go | typescript | all (default: all)
    --files FILE,...    Only parse specific files (for incremental updates)
    --threads N         Parallel file parsing threads (default: CPU count)
    --verbose           Print progress to stderr

EXIT CODES
    0   Success
    1   Parse error (details on stderr)
    2   Invalid arguments
    3   I/O error

EXAMPLE
    cartographer-parser /home/user/myrepo --out /tmp/myrepo.cgraph --lang go
    cartographer-parser /home/user/myrepo --files src/main.go,src/auth.go --out /tmp/delta.cgraph
```

### Engine CLI Interface

```
SYNOPSIS
    cartographer-engine [OPTIONS]

OPTIONS
    --graph PATH        Path to .cgraph file (required)
    --repo PATH         Path to the source repo (required, for git operations)
    --parser PATH       Path to cartographer-parser binary (default: PATH lookup)
    --port N            HTTP server port (default: 8080)
    --layout-iter N     Fruchterman-Reingold iterations (default: 1000)
    --snapshots N       Number of git history snapshots to pre-generate (default: 50)
    --snapshot-dir DIR  Directory to cache snapshots (default: .cartographer/snapshots)
    --watch             Enable filesystem watcher for incremental updates

STARTUP SEQUENCE
    1. Load .cgraph → validate format
    2. Parse git log → annotate node churn scores
    3. Run Fruchterman-Reingold layout → assign (x,y) to all nodes
    4. Build query indexes (KD-tree, trigram search index)
    5. Start background snapshot pre-generation (if --snapshots > 0)
    6. Start HTTP server
    7. Start fsnotify watcher (if --watch)
```

### HTTP API Response Types

All responses are JSON. All timestamps are Unix epoch seconds (integer).

```typescript
// GET /api/graph/stats
interface GraphStats {
    node_count: number;
    edge_count: number;
    file_count: number;
    function_count: number;
    most_complex: { id: number; name: string; file: string; complexity: number };
    most_churned: { id: number; file: string; churn: number };
    avg_complexity: number;
    avg_degree: number;
}

// GET /api/nodes
interface NodeListResponse {
    nodes: NodeSummary[];
    total: number;
}
interface NodeSummary {
    id: number;
    name: string;
    file: string;
    x: number;
    y: number;
    complexity: number;
    churn: number;
    in_degree: number;
    out_degree: number;
    node_type: "file" | "function" | "method";
}

// GET /api/nodes/:id
interface NodeDetail extends NodeSummary {
    line_start: number;
    line_end: number;
    callers: NodeSummary[];    // in-neighbors
    callees: NodeSummary[];    // out-neighbors
}

// GET /api/nodes/:id/radius?r=N
interface RadiusResponse {
    nodes: NodeSummary[];
    center: { x: number; y: number };
    radius: number;
}

// GET /api/path?from=A&to=B
interface PathResponse {
    found: boolean;
    path: NodeSummary[];   // ordered from → to, inclusive
    length: number;
}

// GET /api/search?q=STRING
interface SearchResponse {
    results: Array<NodeSummary & { score: number }>;
}

// GET /api/git/churn?commits=N
interface ChurnResponse {
    commits_analyzed: number;
    files: Array<{ file: string; node_id: number; churn: number }>;
}

// GET /api/history?limit=N
interface HistoryResponse {
    commits: Array<{
        hash: string;
        short_hash: string;
        timestamp: number;
        author: string;
        message: string;
        snapshot_ready: boolean;
    }>;
}

// GET /api/graph/snapshot?commit=HASH
interface SnapshotResponse {
    commit: string;
    timestamp: number;
    nodes: NodeSummary[];
    edges: Array<{ src: number; dst: number; type: string; weight: number }>;
}

// WebSocket message (pushed by server)
interface WsNodeUpdate {
    type: "node_update";
    payload: {
        nodes: Array<{ id: number; x: number; y: number; complexity: number; churn: number }>;
        edges_added: Array<{ src: number; dst: number; type: string; weight: number }>;
        edges_removed: Array<{ src: number; dst: number }>;
    };
}

interface WsSnapshotReady {
    type: "snapshot_ready";
    payload: { commit: string };
}
```

---

## WebGL Shader Reference

### Node Vertex Shader

```glsl
#version 300 es
precision highp float;

// Per-quad vertex (4 vertices per instance)
in vec2 a_quad;       // quad corner in [-1, +1] space

// Per-instance attributes (one per node)
in vec2  a_center;    // world-space center
in float a_radius;    // world-space radius
in vec3  a_color;     // RGB color
in float a_alpha;     // for fade in/out during morph

uniform mat3 u_view;  // view transform (pan + zoom)
uniform vec2 u_resolution;

out vec2  v_uv;
out vec3  v_color;
out float v_alpha;

void main() {
    v_uv    = a_quad;
    v_color = a_color;
    v_alpha = a_alpha;

    vec2 world_pos = a_center + a_quad * a_radius;
    vec3 clip_pos  = u_view * vec3(world_pos, 1.0);
    gl_Position = vec4(clip_pos.xy, 0.0, 1.0);
}
```

### Node Fragment Shader

```glsl
#version 300 es
precision highp float;

in vec2  v_uv;
in vec3  v_color;
in float v_alpha;

out vec4 fragColor;

void main() {
    float dist = length(v_uv);
    if (dist > 1.0) discard;

    // Soft edge antialiasing
    float edge = 1.0 - smoothstep(0.85, 1.0, dist);

    // Inner highlight (top-left quadrant brightens slightly)
    float highlight = 0.15 * max(0.0, dot(normalize(v_uv), vec2(-0.7, 0.7)));
    vec3 color = v_color + highlight;

    fragColor = vec4(color, edge * v_alpha);
}
```

### Edge Vertex Shader

```glsl
#version 300 es
precision highp float;

// Each edge = 6 vertices (2 triangles forming a quad)
in vec2  a_point_a;   // world-space endpoint A
in vec2  a_point_b;   // world-space endpoint B
in float a_thickness; // half-width in world space
in vec3  a_color;
in float a_alpha;
in float a_quad_t;    // 0 or 1 along edge length
in float a_quad_s;    // -1 or +1 perpendicular

uniform mat3 u_view;

out vec3  v_color;
out float v_alpha;

void main() {
    v_color = a_color;
    v_alpha = a_alpha;

    vec2 dir = normalize(a_point_b - a_point_a);
    vec2 perp = vec2(-dir.y, dir.x);

    vec2 world_pos = mix(a_point_a, a_point_b, a_quad_t) + perp * a_thickness * a_quad_s;
    vec3 clip_pos  = u_view * vec3(world_pos, 1.0);
    gl_Position = vec4(clip_pos.xy, 0.0, 1.0);
}
```

### Edge Fragment Shader

```glsl
#version 300 es
precision highp float;

in vec3  v_color;
in float v_alpha;

out vec4 fragColor;

void main() {
    fragColor = vec4(v_color, v_alpha * 0.6);  // edges are semi-transparent
}
```

---

## Color Encoding Reference

### Node Color (Churn Rate)

Churn score is normalized to [0, 1] where 0 = never changed, 1 = changed in almost every commit.

```typescript
function churnToColor(churn: number): [number, number, number] {
    // Blue (stable) → Teal → Yellow → Red (hot)
    const stops = [
        [0.0, [0.20, 0.45, 0.85]],  // cool blue
        [0.3, [0.10, 0.75, 0.65]],  // teal
        [0.6, [0.95, 0.80, 0.10]],  // yellow
        [1.0, [0.90, 0.15, 0.10]],  // hot red
    ];
    // Lerp between stops based on churn value
    return interpolateColorStops(stops, churn);
}
```

### Node Size (Complexity)

```typescript
function complexityToRadius(complexity: number, maxComplexity: number): number {
    const MIN_RADIUS = 4;   // world units
    const MAX_RADIUS = 40;
    // Square root scale: prevents high-complexity nodes from dominating completely
    const t = Math.sqrt(complexity / maxComplexity);
    return MIN_RADIUS + t * (MAX_RADIUS - MIN_RADIUS);
}
```

### Edge Color

Edges inherit a blend of their source and destination node colors, at reduced opacity.

```typescript
function edgeColor(srcColor: Vec3, dstColor: Vec3): Vec3 {
    return lerpColor(srcColor, dstColor, 0.5);
}
```

### District Fill Color

Districts use the average color of their member nodes, heavily desaturated, at ~15% opacity.

---

## Performance Budget

### Frame Budget (16ms at 60fps)

| Task | Budget |
|---|---|
| JavaScript logic (input, state updates) | 1ms |
| VBO updates (WebSocket deltas) | 2ms |
| Edge draw call | 4ms |
| Node draw call | 4ms |
| District + glow passes | 2ms |
| Browser composite + vsync | 3ms |
| **Total** | **16ms** |

### Memory Budget

| Component | Target |
|---|---|
| Go engine (10k node graph) | < 200MB RSS |
| WebGL node VBO | < 10MB |
| WebGL edge VBO | < 30MB |
| Client-side graph model | < 50MB |
| Snapshot cache (50 commits) | < 200MB on disk |

---

## Error Handling Philosophy

**Parser (C++):** Errors are non-fatal per file. If a file fails to parse (malformed source, encoding issues), log the error to stderr and skip the file. The node for that file is still added to the graph but has no outgoing edges and complexity = 0. This is rendered as a gray node in the UI.

**Engine (Go):** HTTP handlers return structured error JSON:
```json
{ "error": "node not found", "code": "NOT_FOUND" }
```
Layout failure is fatal — the engine exits. Query failures return empty results, never 500s for well-formed requests.

**Frontend (TypeScript):** Every WebGL operation is wrapped in an error check. A failed draw call should not crash the entire render loop — log and skip. API failures show a non-blocking toast notification. WebSocket disconnection triggers automatic reconnect with exponential backoff.

---

## Build System

### Root Makefile

```makefile
.PHONY: all parser engine frontend test clean

all: parser engine frontend

parser:
    cd parser && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build

engine:
    cd engine && go build -o bin/cartographer-engine .

frontend:
    cd frontend && npm run build

test:
    cd parser && cmake --build build --target test
    cd engine && go test ./...
    cd frontend && npm run test

clean:
    rm -rf parser/build engine/bin frontend/dist
```

### Development Mode

```bash
# Terminal 1: Run the engine with --watch
cd engine && go run . --graph ../graph.cgraph --repo ../myrepo --watch

# Terminal 2: Run the Vite dev server (hot reload)
cd frontend && npm run dev

# Parser: rebuild and re-run when parser source changes
cd parser && cmake --build build && ./build/cartographer-parser ../myrepo --out ../graph.cgraph
```