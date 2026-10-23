//! The automatic layout: each group of tables joined by foreign keys in
//! columns, the tables a key points at to the left of the tables that
//! hold it, then the groups packed in rows and the tables with no key
//! in a grid after them.

use std::collections::{BTreeMap, VecDeque};

/// Room between two columns, wide enough for an edge's markers and curve.
pub(crate) const COLUMN_GAP: f64 = 96.0;
/// Room between two tables in a column.
pub(crate) const ROW_GAP: f64 = 40.0;
/// Room between two groups of tables.
pub(crate) const GROUP_GAP: f64 = 120.0;

/// Barycenter passes over a group's columns. Four settle the order of
/// the schemas the tests use; more change little.
const ORDER_PASSES: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Size {
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Point {
    pub x: f64,
    pub y: f64,
}

/// Where each table goes, by index, with the top-left corner of the
/// whole layout at the origin. `edges` are (holder, referenced) pairs.
pub(crate) fn arrange(sizes: &[Size], edges: &[(usize, usize)]) -> Vec<Point> {
    let mut positions = vec![Point { x: 0.0, y: 0.0 }; sizes.len()];
    let groups = groups(sizes.len(), edges);
    let total_area: f64 = sizes.iter().map(|size| size.width * size.height).sum();
    let mut blocks: Vec<Block> = Vec::new();
    let mut lone: Vec<usize> = Vec::new();
    for group in groups {
        match group.as_slice() {
            [single] => lone.push(*single),
            _ => blocks.push(layered(&group, sizes, edges)),
        }
    }
    if !lone.is_empty() {
        blocks.push(grid(&lone, sizes, (total_area.sqrt() * 1.6).max(1.0)));
    }
    let row_width = blocks
        .iter()
        .map(|block| block.width)
        .fold((total_area.sqrt() * 1.6).max(1.0), f64::max);
    let (mut x, mut y, mut row_height) = (0.0_f64, 0.0_f64, 0.0_f64);
    for block in blocks {
        if x > 0.0 && x + block.width > row_width {
            x = 0.0;
            y += row_height + GROUP_GAP;
            row_height = 0.0;
        }
        for (table, at) in block.places {
            if let Some(position) = positions.get_mut(table) {
                *position = Point {
                    x: x + at.x,
                    y: y + at.y,
                };
            }
        }
        x += block.width + GROUP_GAP;
        row_height = row_height.max(block.height);
    }
    positions
}

/// Tables placed relative to their group's corner.
struct Block {
    places: Vec<(usize, Point)>,
    width: f64,
    height: f64,
}

/// The tables joined by any chain of keys, each group in index order,
/// the groups in order of their first table.
fn groups(count: usize, edges: &[(usize, usize)]) -> Vec<Vec<usize>> {
    let mut parent: Vec<usize> = (0..count).collect();
    fn root(parent: &mut [usize], mut at: usize) -> usize {
        while parent[at] != at {
            parent[at] = parent[parent[at]];
            at = parent[at];
        }
        at
    }
    for &(from, to) in edges {
        if from >= count || to >= count {
            continue;
        }
        let (a, b) = (root(&mut parent, from), root(&mut parent, to));
        if a != b {
            parent[a.max(b)] = a.min(b);
        }
    }
    let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for table in 0..count {
        let group = root(&mut parent, table);
        groups.entry(group).or_default().push(table);
    }
    let mut groups: Vec<Vec<usize>> = groups.into_values().collect();
    // The largest group first, where the eye lands.
    groups.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.first().cmp(&b.first())));
    groups
}

/// A group in columns by how far each table is from one that references
/// nothing, ordered so keys cross as little as a few passes manage.
fn layered(group: &[usize], sizes: &[Size], edges: &[(usize, usize)]) -> Block {
    let local: BTreeMap<usize, usize> = group.iter().enumerate().map(|(at, &table)| (table, at)).collect();
    let links: Vec<(usize, usize)> = edges
        .iter()
        .filter(|(from, to)| from != to)
        .filter_map(|(from, to)| Some((*local.get(from)?, *local.get(to)?)))
        .collect();
    let layers = layers_of(group.len(), &links);
    let mut columns: Vec<Vec<usize>> = Vec::new();
    for (node, &layer) in layers.iter().enumerate() {
        if columns.len() <= layer {
            columns.resize_with(layer + 1, Vec::new);
        }
        columns[layer].push(node);
    }
    order(&mut columns, &links);
    let size_of = |node: usize| {
        sizes.get(group[node]).copied().unwrap_or(Size {
            width: 0.0,
            height: 0.0,
        })
    };
    let area: f64 = (0..group.len())
        .map(|node| size_of(node).width * size_of(node).height)
        .sum();
    let tallest = (0..group.len()).map(|node| size_of(node).height).fold(0.0, f64::max);
    let limit = (area.sqrt() * 1.2).max(tallest);
    let columns = wrap(columns, limit, &size_of);
    let heights: Vec<f64> = columns.iter().map(|column| stacked_height(column, &size_of)).collect();
    let height = heights.iter().copied().fold(0.0, f64::max);
    let mut places = Vec::with_capacity(group.len());
    let mut x = 0.0;
    for (column, column_height) in columns.iter().zip(&heights) {
        let width = column.iter().map(|&node| size_of(node).width).fold(0.0, f64::max);
        let mut y = (height - column_height) / 2.0;
        for &node in column {
            places.push((group[node], Point { x, y }));
            y += size_of(node).height + ROW_GAP;
        }
        x += width + COLUMN_GAP;
    }
    Block {
        places,
        width: (x - COLUMN_GAP).max(0.0),
        height,
    }
}

fn stacked_height(column: &[usize], size_of: &impl Fn(usize) -> Size) -> f64 {
    let tables: f64 = column.iter().map(|&node| size_of(node).height).sum();
    tables + ROW_GAP * column.len().saturating_sub(1) as f64
}

/// Each node's column: 0 for a node whose keys point nowhere in the
/// group, else one past the furthest table it points at. A cycle of keys
/// is broken at the key that closes it, found by a walk in index order.
fn layers_of(count: usize, links: &[(usize, usize)]) -> Vec<usize> {
    let mut out: Vec<Vec<usize>> = vec![Vec::new(); count];
    for &(from, to) in links {
        if let Some(targets) = out.get_mut(from)
            && !targets.contains(&to)
        {
            targets.push(to);
        }
    }
    let acyclic = without_cycles(&out);
    // Kahn's order from the referenced side: a node's layer is known once
    // every table it points at has one.
    let mut pending: Vec<usize> = acyclic.iter().map(Vec::len).collect();
    let mut incoming: Vec<Vec<usize>> = vec![Vec::new(); count];
    for (from, targets) in acyclic.iter().enumerate() {
        for &to in targets {
            incoming[to].push(from);
        }
    }
    let mut layer = vec![0usize; count];
    let mut ready: VecDeque<usize> = (0..count).filter(|&node| pending[node] == 0).collect();
    while let Some(node) = ready.pop_front() {
        for &holder in &incoming[node] {
            layer[holder] = layer[holder].max(layer[node] + 1);
            pending[holder] -= 1;
            if pending[holder] == 0 {
                ready.push_back(holder);
            }
        }
    }
    layer
}

/// `out` with each key that closes a cycle taken out, walking from each
/// node in index order. Iterative, so a long chain of keys cannot
/// overflow the stack.
fn without_cycles(out: &[Vec<usize>]) -> Vec<Vec<usize>> {
    #[derive(Clone, Copy, PartialEq)]
    enum Mark {
        New,
        Open,
        Done,
    }
    let mut marks = vec![Mark::New; out.len()];
    let mut kept: Vec<Vec<usize>> = vec![Vec::new(); out.len()];
    for start in 0..out.len() {
        if marks[start] != Mark::New {
            continue;
        }
        let mut stack: Vec<(usize, usize)> = vec![(start, 0)];
        marks[start] = Mark::Open;
        while let Some((node, next)) = stack.pop() {
            let Some(&to) = out[node].get(next) else {
                marks[node] = Mark::Done;
                continue;
            };
            stack.push((node, next + 1));
            match marks[to] {
                Mark::Open => {}
                Mark::Done => kept[node].push(to),
                Mark::New => {
                    kept[node].push(to);
                    marks[to] = Mark::Open;
                    stack.push((to, 0));
                }
            }
        }
    }
    kept
}

/// Barycenter ordering: each column sorted by the mean place of the
/// tables it is joined to in the other columns, sweeping right then
/// left. Ties keep their order, so the result is the same every time.
fn order(columns: &mut [Vec<usize>], links: &[(usize, usize)]) {
    let count = columns.iter().map(Vec::len).sum::<usize>();
    let mut neighbours: Vec<Vec<usize>> = vec![Vec::new(); count];
    for &(from, to) in links {
        if from < count && to < count {
            neighbours[from].push(to);
            neighbours[to].push(from);
        }
    }
    let mut place = vec![0.0_f64; count];
    let mark = |columns: &[Vec<usize>], place: &mut [f64]| {
        for column in columns {
            let len = column.len().max(1) as f64;
            for (at, &node) in column.iter().enumerate() {
                place[node] = (at as f64 + 0.5) / len;
            }
        }
    };
    mark(columns, &mut place);
    for pass in 0..ORDER_PASSES {
        let sweep: Vec<usize> = match pass % 2 {
            0 => (1..columns.len()).collect(),
            _ => (0..columns.len().saturating_sub(1)).rev().collect(),
        };
        for at in sweep {
            let column = &mut columns[at];
            let mut keyed: Vec<(f64, usize)> = column
                .iter()
                .map(|&node| {
                    let others = &neighbours[node];
                    let center = if others.is_empty() {
                        place[node]
                    } else {
                        others.iter().map(|&other| place[other]).sum::<f64>() / others.len() as f64
                    };
                    (center, node)
                })
                .collect();
            keyed.sort_by(|a, b| a.0.total_cmp(&b.0));
            *column = keyed.into_iter().map(|(_, node)| node).collect();
            mark(std::slice::from_ref(column), &mut place);
        }
    }
}

/// A column taller than `limit` goes on in a column beside it, so one
/// table that many others point at does not make a tower.
fn wrap(columns: Vec<Vec<usize>>, limit: f64, size_of: &impl Fn(usize) -> Size) -> Vec<Vec<usize>> {
    let mut wrapped = Vec::with_capacity(columns.len());
    for column in columns {
        let mut current: Vec<usize> = Vec::new();
        let mut height = 0.0;
        for node in column {
            let next = size_of(node).height;
            if !current.is_empty() && height + next > limit {
                wrapped.push(std::mem::take(&mut current));
                height = 0.0;
            }
            height += next + ROW_GAP;
            current.push(node);
        }
        if !current.is_empty() {
            wrapped.push(current);
        }
    }
    wrapped
}

/// Tables with no key in rows, in index order, each row as wide as
/// `width` allows.
fn grid(tables: &[usize], sizes: &[Size], width: f64) -> Block {
    let mut places = Vec::with_capacity(tables.len());
    let (mut x, mut y, mut row_height, mut widest) = (0.0_f64, 0.0_f64, 0.0_f64, 0.0_f64);
    for &table in tables {
        let size = sizes.get(table).copied().unwrap_or(Size {
            width: 0.0,
            height: 0.0,
        });
        if x > 0.0 && x + size.width > width {
            x = 0.0;
            y += row_height + ROW_GAP;
            row_height = 0.0;
        }
        places.push((table, Point { x, y }));
        x += size.width + COLUMN_GAP;
        widest = widest.max(x - COLUMN_GAP);
        row_height = row_height.max(size.height);
    }
    Block {
        places,
        width: widest,
        height: y + row_height,
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    fn sizes(count: usize) -> Vec<Size> {
        (0..count)
            .map(|at| Size {
                width: 160.0 + (at % 5) as f64 * 20.0,
                height: 60.0 + (at % 7) as f64 * 25.0,
            })
            .collect()
    }

    fn overlapping(sizes: &[Size], positions: &[Point]) -> Option<(usize, usize)> {
        for a in 0..sizes.len() {
            for b in (a + 1)..sizes.len() {
                let (pa, pb, sa, sb) = (positions[a], positions[b], sizes[a], sizes[b]);
                let apart = pa.x + sa.width <= pb.x
                    || pb.x + sb.width <= pa.x
                    || pa.y + sa.height <= pb.y
                    || pb.y + sb.height <= pa.y;
                if !apart {
                    return Some((a, b));
                }
            }
        }
        None
    }

    #[test]
    fn a_referenced_table_sits_left_of_the_tables_that_hold_its_key() {
        let sizes = sizes(3);
        // orders -> customers, items -> orders.
        let positions = arrange(&sizes, &[(1, 0), (2, 1)]);

        assert!(positions[0].x + sizes[0].width <= positions[1].x, "{positions:?}");
        assert!(positions[1].x + sizes[1].width <= positions[2].x, "{positions:?}");
    }

    #[test]
    fn no_two_tables_overlap() {
        let sizes = sizes(60);
        let edges: Vec<(usize, usize)> = (1..40).map(|at| (at, at / 3)).chain([(45, 46), (46, 45)]).collect();

        let positions = arrange(&sizes, &edges);

        assert_eq!(overlapping(&sizes, &positions), None);
        assert!(positions.iter().all(|point| point.x >= 0.0 && point.y >= 0.0));
    }

    #[test]
    fn cycles_and_self_references_are_laid_out() {
        let sizes = sizes(4);

        let positions = arrange(&sizes, &[(0, 1), (1, 2), (2, 0), (3, 3), (3, 0)]);

        assert_eq!(overlapping(&sizes, &positions), None);
    }

    #[test]
    fn the_same_schema_lays_out_the_same_way() {
        let sizes = sizes(30);
        let edges: Vec<(usize, usize)> = (1..30).map(|at| (at, (at * 7) % at.max(1))).collect();

        assert_eq!(arrange(&sizes, &edges), arrange(&sizes, &edges));
    }

    #[test]
    fn a_table_many_point_at_does_not_make_a_tower() {
        let sizes = sizes(61);
        let edges: Vec<(usize, usize)> = (1..61).map(|at| (at, 0)).collect();

        let positions = arrange(&sizes, &edges);

        let height = (0..61).map(|at| positions[at].y + sizes[at].height).fold(0.0, f64::max);
        let width = (0..61).map(|at| positions[at].x + sizes[at].width).fold(0.0, f64::max);
        assert!(height < width * 3.0, "{width} wide, {height} tall");
        assert_eq!(overlapping(&sizes, &positions), None);
    }

    #[test]
    fn five_hundred_tables_lay_out_quickly() {
        let sizes = sizes(500);
        let edges: Vec<(usize, usize)> = (1..500).filter(|at| at % 4 != 0).map(|at| (at, at / 2)).collect();

        let started = Instant::now();
        let positions = arrange(&sizes, &edges);

        assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
        assert_eq!(positions.len(), 500);
    }
}
