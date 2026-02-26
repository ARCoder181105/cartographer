# 📐 Cartographer — Algorithms Reference

Deep-dive pseudocode, mathematical analysis, and implementation guidance for every significant algorithm in Cartographer.

---

## 1. Fruchterman-Reingold Force-Directed Layout

### Overview

Fruchterman-Reingold (1991) models a graph as a physical system:
- Nodes are charged particles — they **repel** each other
- Edges are springs — they **attract** connected nodes
- A global "temperature" controls the maximum displacement per step and decreases over time (simulated annealing)

The system reaches equilibrium when forces balance — at this point, strongly connected nodes are spatially close and weakly connected nodes are far apart.

### Mathematical Definition

Let G = (V, E) be the graph, |V| = n nodes, area = W × H.

```
k = C × √(area / n)          # ideal spring length, C ≈ 1.0 (tuning constant)

Repulsive force between u and v (any pair, u ≠ v):
    f_r(d) = k² / d          # d = distance between u and v

Attractive force between u and v (only if edge (u,v) exists):
    f_a(d) = d² / k          # d = distance between u and v
```

Note: f_r decreases with distance (inverse), f_a increases with distance (direct). The equilibrium distance is when f_r = f_a → k² / d = d² / k → d³ = k³ → d = k. Connected nodes settle at distance k from each other.

### Full Algorithm

```
INPUT:  G = (V, E), canvas W × H, max_iterations, C
OUTPUT: (x_i, y_i) for each node i

INITIALIZE:
    k ← C × sqrt(W × H / |V|)
    t ← W / 10                           # initial temperature
    for each v in V:
        v.pos ← random point in [0,W] × [0,H]

FOR iter = 1 to max_iterations:

    # --- REPULSIVE FORCES ---
    for each v in V:
        v.disp ← (0, 0)

    for each pair (u, v) in V × V where u ≠ v:
        Δ ← v.pos - u.pos
        d ← max(‖Δ‖, 0.001)             # avoid division by zero
        f ← k² / d
        unit ← Δ / d
        v.disp ← v.disp + unit × f
        u.disp ← u.disp - unit × f      # Newton's third law

    # --- ATTRACTIVE FORCES ---
    for each edge (u, v) in E:
        Δ ← v.pos - u.pos
        d ← max(‖Δ‖, 0.001)
        f ← d² / k
        unit ← Δ / d
        v.disp ← v.disp - unit × f
        u.disp ← u.disp + unit × f

    # --- APPLY DISPLACEMENTS (clamped by temperature) ---
    for each v in V:
        disp_len ← max(‖v.disp‖, 0.001)
        displacement ← (v.disp / disp_len) × min(disp_len, t)
        v.pos ← v.pos + displacement
        v.pos.x ← clamp(v.pos.x, padding, W - padding)
        v.pos.y ← clamp(v.pos.y, padding, H - padding)

    # --- COOL ---
    t ← t × (1 - iter / max_iterations)

NORMALIZE:
    # Scale all positions to fit within output bounds
    x_min ← min(v.pos.x for v in V)
    x_max ← max(v.pos.x for v in V)
    y_min ← min(v.pos.y for v in V)
    y_max ← max(v.pos.y for v in V)
    for each v in V:
        v.pos.x ← (v.pos.x - x_min) / (x_max - x_min) × output_width
        v.pos.y ← (v.pos.y - y_min) / (y_max - y_min) × output_height
```

### Spatial Grid Optimization

Naive implementation is O(n²) per iteration. For n = 15,000 nodes and 1000 iterations = **2.25 × 10¹¹ operations**. Unusable.

The key insight: repulsive force f_r(d) = k²/d → at distance d = 10k, force is only 10% of the force at k. At d = 100k, it's 1%. We can safely ignore repulsions beyond ~3k.

**Grid construction:**

Divide the canvas into a grid with cell size = 3k. When computing repulsion for node v, only check nodes in the 9 neighboring cells (3×3 neighborhood). This reduces repulsion to O(n × avg_density) per iteration.

```
BUILD GRID:
    cell_size ← 3 × k
    grid ← empty hash map: (int, int) → []NodeID

    for each v in V:
        cx ← floor(v.pos.x / cell_size)
        cy ← floor(v.pos.y / cell_size)
        grid[(cx, cy)].append(v.id)

QUERY NEARBY NODES (for node v):
    cx ← floor(v.pos.x / cell_size)
    cy ← floor(v.pos.y / cell_size)
    nearby ← []
    for dx in {-1, 0, 1}:
        for dy in {-1, 0, 1}:
            nearby.extend(grid[(cx+dx, cy+dy)])
    return nearby
```

Rebuild the grid at the start of each iteration. With uniform distribution, each cell contains ~9 nodes on average, making the repulsion step O(9n) = O(n) per iteration.

**Total complexity:** O(n × max_iterations) ← from O(n² × max_iterations). For n=15,000, iter=1,000: ~1.5 × 10⁸ operations. Feasible in < 30 seconds.

### Parallelization in Go

The repulsion computation for each node is independent (reads positions, writes to v.disp). Parallelize with goroutines:

```go
func computeRepulsion(graph *Graph, grid *Grid, k float64, wg *sync.WaitGroup) {
    chunkSize := len(graph.Nodes) / runtime.NumCPU()
    for start := 0; start < len(graph.Nodes); start += chunkSize {
        end := min(start+chunkSize, len(graph.Nodes))
        wg.Add(1)
        go func(s, e int) {
            defer wg.Done()
            for i := s; i < e; i++ {
                v := &graph.Nodes[i]
                for _, uid := range grid.nearby(v.X, v.Y) {
                    if uid == uint32(i) { continue }
                    u := &graph.Nodes[uid]
                    dx := v.X - u.X
                    dy := v.Y - u.Y
                    d := math.Max(math.Sqrt(dx*dx+dy*dy), 0.001)
                    f := k * k / d
                    v.DispX += (dx / d) * f
                    v.DispY += (dy / d) * f
                }
            }
        }(start, end)
    }
    wg.Wait()
}
```

Note: `DispX`/`DispY` writes are per-node and non-overlapping between goroutines, so no mutex needed.

---

## 2. BFS Shortest Path

### Use Case

`GET /api/path?from=A&to=B` — find the shortest call path between two functions. "Shortest" means fewest intermediate calls, not minimum edge weight.

### Algorithm

Standard BFS over the directed call graph. The graph is directed (calls flow from caller to callee), so the path found is a valid call chain.

```
BFS_PATH(G, src, dst):
    if src == dst: return [src]

    queue ← deque([src])
    predecessor ← {src: NONE}    # maps node → where we came from

    while queue is not empty:
        cur ← queue.popleft()
        if cur == dst:
            return reconstruct_path(predecessor, src, dst)

        for each neighbor in G.OutEdges[cur]:
            if neighbor not in predecessor:
                predecessor[neighbor] ← cur
                queue.append(neighbor)

    return []   # no path exists

RECONSTRUCT_PATH(predecessor, src, dst):
    path ← []
    cur ← dst
    while cur != src:
        path.prepend(cur)
        cur ← predecessor[cur]
    path.prepend(src)
    return path
```

**Complexity:** O(V + E) — linear in graph size.

**Note on directed vs undirected:** The call graph is directed. If you want "is there any connection (caller or callee)" you need to run BFS on the **undirected** version. Consider exposing both: `?directed=true` for call chains, `?directed=false` for reachability.

---

## 3. KD-Tree for Spatial Queries

### Use Case

`GET /api/nodes/:id/radius?r=N` — find all nodes within world-space radius R of a given node.

Also used client-side in TypeScript for mouse hit testing (find node closest to cursor click).

### Algorithm

A KD-tree is a binary tree that recursively partitions 2D space along alternating axes (X at even depth, Y at odd depth). It supports O(log n) nearest-neighbor and range queries.

```
BUILD_KDTREE(points, depth=0):
    if points is empty: return NULL

    axis ← depth mod 2        # 0 = split on X, 1 = split on Y
    sort points by axis
    median ← len(points) / 2

    node.point ← points[median]
    node.left  ← BUILD_KDTREE(points[:median], depth+1)
    node.right ← BUILD_KDTREE(points[median+1:], depth+1)
    return node

RANGE_QUERY(kdtree_node, target, radius, result=[]):
    if kdtree_node is NULL: return

    dist ← distance(kdtree_node.point, target)
    if dist <= radius:
        result.append(kdtree_node.point)

    axis ← kdtree_node.depth mod 2
    axis_diff ← target[axis] - kdtree_node.point[axis]

    # Determine which subtree to search first
    if axis_diff <= 0:
        near, far ← kdtree_node.left, kdtree_node.right
    else:
        near, far ← kdtree_node.right, kdtree_node.left

    RANGE_QUERY(near, target, radius, result)

    # Only search far subtree if the splitting plane is within radius
    if abs(axis_diff) <= radius:
        RANGE_QUERY(far, target, radius, result)

    return result
```

**Complexity:** O(log n) amortized for range queries.

**Implementation note:** Rebuild the KD-tree after layout completes and after any incremental update that moves nodes. For 15,000 nodes, rebuild takes ~5ms — acceptable.

---

## 4. Trigram Fuzzy Search

### Use Case

`GET /api/search?q=STRING` — find nodes whose name approximately matches the query.

### Algorithm

A trigram index breaks every string into 3-character substrings ("trigrams"). Two strings are similar if they share many trigrams.

```
TRIGRAMS(s):
    # Pad string for edge trigrams
    s ← "  " + s + " "
    result ← set()
    for i in range(len(s) - 2):
        result.add(s[i:i+3])
    return result

Example: TRIGRAMS("main") = {"  m", " ma", "mai", "ain", "in "}

BUILD_INDEX(nodes):
    index ← hash map: trigram → []NodeID
    for each node v:
        for each trigram t in TRIGRAMS(v.name.lower()):
            index[t].append(v.id)

SEARCH(query, index, nodes, limit=20):
    query_trigrams ← TRIGRAMS(query.lower())
    scores ← hash map: NodeID → int (count of shared trigrams)

    for each trigram t in query_trigrams:
        for each node_id in index[t]:
            scores[node_id] += 1

    # Normalize by max possible shared trigrams
    # Jaccard-like similarity: shared / (|A| + |B| - shared)
    results ← []
    for (node_id, shared) in scores:
        node_trigrams_count ← TRIGRAMS(nodes[node_id].name).size()
        query_trigrams_count ← query_trigrams.size()
        score ← shared / (node_trigrams_count + query_trigrams_count - shared)
        results.append((score, node_id))

    sort results by score descending
    return results[:limit]
```

**Complexity:** Index build O(n × avg_name_length). Query O(|query_trigrams| × avg_bucket_size + result_sort). Effectively O(1) for typical queries.

---

## 5. Convex Hull (Graham Scan)

### Use Case

Rendering district boundaries. Given a set of (x, y) node positions belonging to the same package, compute their convex hull to draw the district outline.

### Algorithm

Graham scan runs in O(n log n).

```
CONVEX_HULL(points):
    if |points| < 3: return points

    # Step 1: Find pivot — lowest y, break ties with lowest x
    pivot ← point with minimum (y, x) in points

    # Step 2: Sort remaining points by polar angle from pivot
    others ← points excluding pivot
    sort others by atan2(p.y - pivot.y, p.x - pivot.x)

    # Step 3: Graham scan
    hull ← [pivot, others[0]]

    for i from 1 to |others| - 1:
        p ← others[i]
        # While the last three points make a clockwise turn (or are collinear),
        # the middle point is inside the hull — remove it
        while |hull| > 1 and cross(hull[-2], hull[-1], p) <= 0:
            hull.pop()
        hull.push(p)

    return hull

CROSS(O, A, B):
    # Cross product of vectors OA and OB
    # > 0: counter-clockwise (left turn)
    # = 0: collinear
    # < 0: clockwise (right turn)
    return (A.x - O.x) × (B.y - O.y) - (A.y - O.y) × (B.x - O.x)
```

### Rendering Convex Hulls in WebGL

The hull polygon is a simple triangle fan from the centroid:

```
Centroid = average of all hull points

Triangles:
    (centroid, hull[0], hull[1])
    (centroid, hull[1], hull[2])
    ...
    (centroid, hull[n-1], hull[0])
```

Render with additive blending at low opacity for the fill, and a line loop for the outline.

---

## 6. Git Churn Score

### Overview

Churn measures how frequently a file changes. High churn = high maintenance burden and potential instability. We compute it by parsing `git log`.

### Algorithm

```
COMPUTE_CHURN(repo_path, commit_count):
    # Get log: one line per commit, list of changed files
    output ← exec("git -C repo_path log --name-only --format='%H' -n commit_count")

    file_change_count ← hash map: string → int

    for each line in output:
        if line is a commit hash: continue
        if line is empty: continue
        file_change_count[line] += 1

    max_count ← max(file_change_count.values())

    churn_scores ← {}
    for (file, count) in file_change_count:
        # Normalize to [0, 65535] for uint16 storage
        churn_scores[file] ← round((count / max_count) × 65535)

    return churn_scores
```

Then for each Node in the graph: if `node.file` is in `churn_scores`, set `node.churn` to the corresponding value.

Files not touched in the last N commits get churn = 0 (stable).

---

## 7. Graph Snapshot Morphing

### Use Case

When the user moves the git history slider, animate smoothly between two graph snapshots.

### Algorithm

```
DIFF_SNAPSHOTS(snapshotA, snapshotB):
    nodesA ← {node.name → node for node in snapshotA.nodes}
    nodesB ← {node.name → node for node in snapshotB.nodes}

    common  ← {name: (nodeA, nodeB) for name in nodesA ∩ nodesB}
    removed ← {name: nodeA for name in nodesA - nodesB}
    added   ← {name: nodeB for name in nodesB - nodesA}

    return Diff(common, removed, added)

ANIMATE_MORPH(diff, duration_ms):
    start_time ← now()

    ON_FRAME():
        t ← (now() - start_time) / duration_ms
        t ← ease_in_out(t)              # cubic easing
        if t >= 1.0: t = 1.0; done = true

        for (nodeA, nodeB) in diff.common:
            x ← lerp(nodeA.x, nodeB.x, t)
            y ← lerp(nodeA.y, nodeB.y, t)
            color ← lerp_color(churn_to_color(nodeA.churn), churn_to_color(nodeB.churn), t)
            radius ← lerp(complexity_to_radius(nodeA.complexity), complexity_to_radius(nodeB.complexity), t)
            update_node_vbo(nodeA.id, x, y, color, radius, alpha=1.0)

        for nodeA in diff.removed:
            # Scale down + fade out
            alpha ← lerp(1.0, 0.0, t)
            scale ← lerp(1.0, 0.0, t)
            update_node_vbo(nodeA.id, nodeA.x, nodeA.y, gray, radius * scale, alpha)

        for nodeB in diff.added:
            # Scale up + fade in
            alpha ← lerp(0.0, 1.0, t)
            scale ← lerp(0.0, 1.0, t)
            update_node_vbo(nodeB.id, nodeB.x, nodeB.y, churn_color, radius * scale, alpha)

        request_animation_frame(ON_FRAME)
```

### Easing Function

```typescript
function easeInOut(t: number): number {
    return t < 0.5
        ? 4 * t * t * t
        : 1 - Math.pow(-2 * t + 2, 3) / 2;
}
```

---

## 8. Incremental Layout Refinement

When a single file changes, we run a partial layout — only on the affected subgraph — to avoid a full 30-second re-layout.

### Neighborhood Extraction

```
GET_NEIGHBORHOOD(graph, changed_node_ids, hop_count=2):
    neighborhood ← set(changed_node_ids)

    for hop in range(hop_count):
        frontier ← set()
        for node_id in neighborhood:
            frontier.update(graph.OutEdges[node_id])
            frontier.update(graph.InEdges[node_id])
        neighborhood.update(frontier)

    return neighborhood
```

### Partial Layout

Run F-R with:
- Only nodes in `neighborhood` have their positions updated
- Nodes outside `neighborhood` are treated as fixed anchors — they contribute repulsive/attractive forces but don't move
- Temperature starts at `k / 5` (small — only fine-tune, don't scramble)
- Run for 50 iterations

This converges quickly and produces good local results because distant nodes have negligible force interactions.