import CoreGraphics
import Foundation

/// The interactive map: one HTML file with everything inside it, screenshots
/// included. Nothing to serve or install, no network, so a private app's screens
/// stay on this machine until someone chooses to send the file.
public struct MapPage {
    private let graph: AtlasGraph
    private let run: CaptureRun?
    private let layout: AtlasLayout
    private let paths: Paths

    public init(graph: AtlasGraph, run: CaptureRun?, layout: AtlasLayout, paths: Paths) {
        self.graph = graph
        self.run = run
        self.layout = layout
        self.paths = paths
    }

    struct Payload: Encodable {
        struct Node: Encodable {
            var id: String
            var title: String
            var group: String?
            var source: String?
            var status: String
            var heading: String?
            var note: String?
            var steps: [String]?
            var labels: [String]?
            var image: String?
            var x: Double
            var y: Double
            var isRoot: Bool
            var isBoundary: Bool
        }

        struct Edge: Encodable {
            var from: String
            var to: String
            var kind: String
            var label: String?
            var raw: String?
            var source: String?
            var d: String
            var labelX: Double
            var labelY: Double
            var isBack: Bool
            var originX: Double?
            var originY: Double?
            var spotX: Double?
            var spotY: Double?
            var spotWidth: Double?
            var spotHeight: Double?
        }

        struct Gap: Encodable {
            var screen: String
            var raw: String
            var source: String
        }

        var name: String
        var details: [String]
        var width: Double
        var height: Double
        var cardWidth: Double
        var phoneHeight: Double
        var nodes: [Node]
        var edges: [Edge]
        var gaps: [Gap]
    }

    public func write() throws {
        let json = try Self.embeddable(JSONEncoder().encode(payload()))
        let html = Self.template
            .replacingOccurrences(of: "__TITLE__", with: Self.escapeHTML(graph.name))
            .replacingOccurrences(of: "__ATLAS__", with: json)
        try html.write(to: paths.map, atomically: true, encoding: .utf8)
    }

    func payload() -> Payload {
        var details = ["\(graph.nodes.count) screens", "\(graph.edges.count) connections"]
        if let device = run?.device { details.append(device) }
        if let runtime = run?.runtime { details.append(runtime) }
        if let commit = run?.commit { details.append(commit) }
        if let date = run?.capturedAt { details.append(date.formatted(date: .abbreviated, time: .shortened)) }

        let nodes = graph.nodes.map { node -> Payload.Node in
            let result = run?.results[node.id]
            let frame = layout.frames[node.id] ?? .zero
            let status: String
            var heading: String?
            var note: String?
            if let skip = node.skip {
                (status, heading, note) = ("skipped", "Skipped", skip)
            } else if let result {
                status = result.status
                if status != "ok" {
                    heading = status == "crashed" ? "Crashed" : "Didn't get there"
                    note = result.note
                }
            } else {
                (status, heading, note) = ("none", "No route yet", node.routeNote)
            }
            return .init(
                id: node.id, title: node.title, group: node.group,
                source: node.file.map { "\($0):\(node.line ?? 1)" },
                status: status, heading: heading, note: note,
                steps: node.steps?.map(\.summary),
                labels: status == "ok" ? nil : result?.visibleLabels,
                image: result?.file.flatMap(dataURI),
                x: Double(frame.minX), y: Double(frame.minY),
                isRoot: node.isRoot, isBoundary: node.isBoundary
            )
        }
        let edges = layout.edges.map { routed -> Payload.Edge in
            let edge = routed.edge
            return .init(
                from: edge.from, to: edge.to, kind: edge.kind.rawValue, label: edge.label, raw: edge.raw,
                source: edge.file.map { "\($0):\(edge.line ?? 1)" },
                d: Self.svgPath(routed.curves),
                labelX: Double(routed.labelCenter.x), labelY: Double(routed.labelCenter.y),
                isBack: routed.isBack,
                originX: routed.origin.map { Double($0.x) }, originY: routed.origin.map { Double($0.y) },
                spotX: routed.spot.map { Double($0.minX) }, spotY: routed.spot.map { Double($0.minY) },
                spotWidth: routed.spot.map { Double($0.width) }, spotHeight: routed.spot.map { Double($0.height) }
            )
        }
        return Payload(
            name: graph.name, details: details,
            width: Double(layout.size.width), height: Double(layout.size.height),
            cardWidth: Double(AtlasLayout.cardWidth),
            phoneHeight: Double(AtlasLayout.cardWidth * AtlasLayout.screenAspect),
            nodes: nodes, edges: edges,
            gaps: graph.unresolved.map { .init(screen: $0.screen, raw: $0.raw, source: "\($0.file):\($0.line)") }
        )
    }

    private func dataURI(_ file: String) -> String? {
        let url = paths.screens.appendingPathComponent(file)
        guard let image = Images.load(url, maxPixels: 1500), let data = Images.jpeg(image, quality: 0.82) else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    static func svgPath(_ curves: [AtlasLayout.Curve]) -> String {
        guard let first = curves.first else { return "" }
        func text(_ point: CGPoint) -> String { String(format: "%.1f %.1f", point.x, point.y) }
        var path = "M\(text(first.start))"
        for curve in curves {
            path += "C\(text(curve.control1)) \(text(curve.control2)) \(text(curve.end))"
        }
        return path
    }

    /// JSON that is safe inside a `<script>`: a screen title containing `</script>`
    /// would otherwise end the block and put the rest of the title into the page.
    static func embeddable(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AtlasError("Couldn't encode the map data.")
        }
        return text.replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>__TITLE__</title>
    <style>
    /* Apple's semantic colours, so this reads as the system's own and follows its dark mode. */
    :root {
      color-scheme: light dark;
      --canvas: #fbfbfd; --surface: #ffffff; --fill: rgba(118, 118, 128, .12); --label: #000000;
      --secondary: rgba(60, 60, 67, .6); --tertiary: rgba(60, 60, 67, .3); --separator: rgba(60, 60, 67, .18);
      --tint: #007aff; --red: #ff3b30; --line: #aeaeb2; --sidebar: #efeff4;
      --card-shadow: 0 1px 2px rgba(0, 0, 0, .05), 0 10px 28px rgba(0, 0, 0, .10);
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --canvas: #111113; --surface: #2a2a2d; --fill: rgba(118, 118, 128, .24); --label: #ffffff;
        --secondary: rgba(235, 235, 245, .6); --tertiary: rgba(235, 235, 245, .3); --separator: rgba(84, 84, 88, .65);
        --tint: #0a84ff; --red: #ff453a; --line: #636366; --sidebar: #1b1b1e;
        --card-shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 10px 28px rgba(0, 0, 0, .5);
      }
    }
    :root[data-theme="dark"] {
      --canvas: #111113; --surface: #2a2a2d; --fill: rgba(118, 118, 128, .24); --label: #ffffff;
      --secondary: rgba(235, 235, 245, .6); --tertiary: rgba(235, 235, 245, .3); --separator: rgba(84, 84, 88, .65);
      --tint: #0a84ff; --red: #ff453a; --line: #636366; --sidebar: #1b1b1e;
      --card-shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 10px 28px rgba(0, 0, 0, .5);
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; margin: 0; }
    body {
      background: var(--canvas); color: var(--label); overflow: hidden;
      font: 15px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    button, input { font: inherit; color: inherit; }
    button { cursor: pointer; border: 0; background: none; padding: 0; }
    :focus-visible { outline: 2px solid var(--tint); outline-offset: 2px; }

    /* The map */
    /* Not selectable: otherwise a drag to pan also selects every screenshot it passes over. */
    #canvas {
      position: fixed; inset: 0; overflow: hidden; cursor: grab; touch-action: none; background: var(--canvas);
      -webkit-user-select: none; user-select: none;
    }
    #canvas img { -webkit-user-drag: none; }
    #canvas.dragging { cursor: grabbing; }
    #world { position: absolute; left: 0; top: 0; transform-origin: 0 0; will-change: transform; }
    #world.flying { transition: transform .32s cubic-bezier(.2, .8, .2, 1); }
    #edges { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; }
    .edge { fill: none; stroke: var(--line); stroke-width: 1.25; stroke-linecap: round; transition: opacity .15s; }
    .edge.sheet { stroke-dasharray: 5 4; }
    .edge.cover { stroke-dasharray: 11 4; }
    .edge.back { stroke-dasharray: 1.5 4; }
    .edge.on { stroke: var(--tint); stroke-width: 2; }
    .pill {
      position: absolute; transform: translate(-50%, -50%); max-width: 180px; padding: 0 5px; border-radius: 5px;
      background: var(--canvas); color: var(--secondary); font-size: 11px; line-height: 16px;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; pointer-events: none; transition: opacity .15s;
    }
    .pill.on { color: var(--tint); font-weight: 600; }
    .origin { fill: var(--line); stroke: var(--surface); stroke-width: 1.5; transition: opacity .15s; }
    .origin.on { fill: var(--tint); }
    /* The element an arrow starts on, lit up while its screen is selected. */
    .spot {
      position: absolute; border-radius: 7px; pointer-events: none; opacity: 0; transition: opacity .15s;
      box-shadow: 0 0 0 1.5px var(--tint); background: color-mix(in srgb, var(--tint) 14%, transparent);
    }
    .spot.on { opacity: 1; }

    .card { position: absolute; display: flex; flex-direction: column; text-align: center; transition: opacity .15s; }
    .card .phone {
      position: relative; display: block; overflow: hidden; border-radius: 30px; background: var(--surface);
      box-shadow: 0 0 0 .5px var(--separator), var(--card-shadow); transition: box-shadow .15s;
    }
    .card .title {
      display: block; margin-top: 9px; font-size: 13px; line-height: 17px; font-weight: 600;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    }
    .card.selected .phone { box-shadow: 0 0 0 2.5px var(--canvas), 0 0 0 5px var(--tint), var(--card-shadow); }
    .card.selected .title { color: var(--tint); }
    .card img { display: block; width: 100%; height: 100%; object-fit: cover; }
    .card.problem .title { color: var(--red); }
    .veil {
      position: absolute; inset: 0; display: flex; flex-direction: column; gap: 6px; padding: 54px 16px; text-align: left;
      background: color-mix(in srgb, var(--surface) 92%, transparent); font-size: 12px; line-height: 1.4;
      color: var(--secondary); overflow-wrap: anywhere;
    }
    .veil strong { color: var(--label); font-size: 15px; line-height: 1.2; font-weight: 600; }
    .dim { opacity: .14; }

    /* Chrome */
    #summary, #tools { position: fixed; z-index: 3; }
    #summary h1 { margin: 0; }
    #summary p { margin: 0; color: var(--secondary); }
    #tools { display: flex; align-items: center; gap: 4px; }
    #search {
      width: 170px; height: 32px; padding: 0 10px 0 30px; border: 0; border-radius: 10px; background-color: var(--fill);
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='7' cy='7' r='4.6' fill='none' stroke='%238e8e93' stroke-width='1.6'/%3E%3Cpath d='M10.5 10.5 14 14' stroke='%238e8e93' stroke-width='1.6' stroke-linecap='round'/%3E%3C/svg%3E");
      background-repeat: no-repeat; background-position: 9px center; background-size: 15px; font-size: 14px;
    }
    #search:focus { outline: none; box-shadow: 0 0 0 2px var(--tint); }
    #search::placeholder { color: var(--secondary); }
    .tool { min-width: 32px; height: 32px; padding: 0 10px; border-radius: 16px; font-size: 14px; font-weight: 500; color: var(--tint); }
    .tool:hover { background: var(--fill); }
    .divider { width: .5px; height: 20px; margin: 0 6px; background: var(--separator); }
    #legend { display: flex; gap: 12px; color: var(--secondary); font-size: 12px; align-items: center; padding: 0 6px; }
    #legend span { display: inline-flex; align-items: center; gap: 5px; white-space: nowrap; }
    #legend svg { display: block; overflow: visible; }

    /* The inspector, as an inset-grouped list */
    #panel {
      position: fixed; z-index: 4; overflow-y: auto; padding: 14px 16px 24px; max-width: 100vw;
      transform: translateX(calc(100% + 24px)); visibility: hidden; transition: transform .26s cubic-bezier(.2, .8, .2, 1), visibility .26s;
    }
    #panel.open { transform: none; visibility: visible; }
    #panel header { display: flex; align-items: center; gap: 6px; }
    #panel h2 { flex: 1; min-width: 0; margin: 0; font-size: 22px; line-height: 28px; font-weight: 700; overflow-wrap: anywhere; }
    .round {
      flex: none; width: 30px; height: 30px; border-radius: 15px; background: var(--fill); color: var(--secondary);
      font-size: 18px; line-height: 28px; font-weight: 500;
    }
    .round:hover { color: var(--label); }
    #panel .position { margin: 0 0 14px; color: var(--secondary); font-size: 13px; }
    #panel .shot { display: block; width: 100%; border-radius: 34px; box-shadow: 0 0 0 .5px var(--separator), var(--card-shadow); }
    #panel h3 { margin: 22px 16px 6px; font-size: 13px; line-height: 18px; font-weight: 400; color: var(--secondary); }
    .group { display: block; margin: 0; padding: 0; list-style: none; overflow: hidden; border-radius: 12px; background: var(--surface); }
    .group > li { position: relative; }
    .group > li + li::before { content: ""; position: absolute; left: 16px; right: 0; top: 0; height: .5px; background: var(--separator); }
    .row { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; width: 100%; min-height: 44px; padding: 11px 16px; text-align: left; }
    .row small { flex: none; max-width: 58%; font-size: 15px; color: var(--secondary); text-align: right; overflow-wrap: anywhere; }
    button.row { padding-right: 30px; position: relative; }
    button.row::after { content: "\203A"; position: absolute; right: 14px; top: 50%; transform: translateY(-52%); font-size: 20px; color: var(--tertiary); }
    button.row:hover { background: var(--fill); }
    .row .number { flex: none; width: 18px; color: var(--secondary); }
    .row .grow { flex: 1; min-width: 0; overflow-wrap: anywhere; }
    .row code { font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--secondary); text-align: right; overflow-wrap: anywhere; min-width: 0; }
    .problem-note { margin: 0 0 14px; padding: 12px 16px; border-radius: 12px; background: var(--surface); overflow-wrap: anywhere; color: var(--secondary); font-size: 14px; }
    .problem-note strong { display: block; color: var(--red); font-weight: 600; margin-bottom: 2px; }
    details { margin: 22px 16px 0; color: var(--secondary); font-size: 13px; }
    summary { cursor: pointer; }
    details code { font: 11.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
    details ul { padding-left: 16px; }

    /* A Mac app's shape: a sidebar listing every screen, a toolbar over the map, a docked inspector. */
    #sidebar {
      position: fixed; z-index: 3; left: 0; top: 0; bottom: 0; width: 244px; overflow-y: auto; padding: 78px 10px 16px;
      background: var(--sidebar); box-shadow: .5px 0 0 var(--separator);
    }
    #summary { z-index: 5; left: 0; top: 0; width: 244px; height: 66px; padding: 14px 20px 0; background: var(--sidebar); }
    #summary h1 { font-size: 15px; line-height: 19px; font-weight: 700; }
    #summary p { font-size: 11px; line-height: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    #tools {
      left: 244px; right: 0; top: 0; height: 52px; padding: 0 12px;
      background: color-mix(in srgb, var(--canvas) 80%, transparent); -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);
      box-shadow: 0 .5px 0 var(--separator);
    }
    #panel { top: 0; right: 0; bottom: 0; width: 340px; background: var(--sidebar); box-shadow: -.5px 0 0 var(--separator); }
    #sidebar h4 { margin: 14px 10px 4px; font-size: 11px; font-weight: 600; color: var(--secondary); }
    #sidebar h4:first-child { margin-top: 0; }
    #sidebar button { display: flex; align-items: center; justify-content: space-between; gap: 6px; width: 100%; height: 28px; padding: 0 10px; border-radius: 6px; font-size: 13px; text-align: left; }
    #sidebar button span:first-child { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    /* `display` above would otherwise win over the hidden attribute. */
    #sidebar button[hidden] { display: none; }
    #sidebar button:hover { background: var(--fill); }
    #sidebar button.selected { background: var(--tint); color: #fff; }
    #sidebar .mark { flex: none; width: 7px; height: 7px; border-radius: 50%; background: var(--red); }

    @media (max-width: 1100px) { #legend, #legend-divider { display: none; } }
    /* Too narrow for three panes: the map and its toolbar come first. */
    @media (max-width: 820px) {
      #sidebar, #summary { display: none; }
      #tools { left: 0; }
    }
    @media (max-width: 720px) {
      #search { width: 110px; }
      #panel { width: 100vw; left: 0; }
    }
    @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
    </style>
    </head>
    <body>
    <div id="canvas"><div id="world"></div></div>
    <nav id="sidebar" aria-label="Screens"></nav>
    <div id="summary"><h1></h1><p></p></div>
    <div id="tools">
      <input id="search" type="search" placeholder="Search" aria-label="Find a screen">
      <button class="tool" id="zoom-out" aria-label="Zoom out">&minus;</button>
      <button class="tool" id="zoom-in" aria-label="Zoom in">+</button>
      <button class="tool" id="fit" title="Fit everything (f)">Fit</button>
      <button class="tool" id="start" title="Step through every screen (j and k)">Review</button>
      <span class="divider" id="legend-divider"></span>
      <div id="legend" aria-label="Legend"></div>
    </div>
    <aside id="panel" aria-label="Screen details"></aside>
    <script id="atlas" type="application/json">__ATLAS__</script>
    <script>
    "use strict";
    const atlas = JSON.parse(document.getElementById("atlas").textContent);
    const SVG = "http://www.w3.org/2000/svg";
    const canvas = document.getElementById("canvas");
    const world = document.getElementById("world");
    const panel = document.getElementById("panel");
    const sidebar = document.getElementById("sidebar");
    const search = document.getElementById("search");
    const nodesById = new Map(atlas.nodes.map(node => [node.id, node]));
    const cards = new Map();
    const sidebarRows = new Map();
    const sidebarAreas = [];
    const edgeViews = [];
    let view = { x: 0, y: 0, k: 1 };
    let selected = null;

    function element(tag, className, text) {
      const made = document.createElement(tag);
      if (className) made.className = className;
      if (text !== undefined) made.textContent = text;
      return made;
    }

    // Some browsers refuse this on a file:// page. The address is a convenience,
    // and the map works the same without it.
    function setAddress(url) {
      try { history.replaceState(null, "", url); } catch {}
    }

    // MARK: Drawing

    function drawLegend() {
      const legend = document.getElementById("legend");
      const drawn = new Set(atlas.edges.map(edge => edge.isBack ? "back" : edge.kind));
      for (const [name, style] of [["Push", "push"], ["Sheet", "sheet"], ["Full screen", "cover"], ["Back", "back"]]) {
        if (!drawn.has(style)) continue;
        const entry = element("span");
        const svg = document.createElementNS(SVG, "svg");
        svg.setAttribute("width", "26");
        svg.setAttribute("height", "4");
        const line = document.createElementNS(SVG, "path");
        line.setAttribute("d", "M1 2H25");
        line.setAttribute("class", "edge " + style);
        svg.append(line);
        entry.append(svg, name);
        legend.append(entry);
      }
      if (!legend.children.length) document.getElementById("legend-divider").remove();
    }

    function drawEdges() {
      const svg = document.createElementNS(SVG, "svg");
      svg.id = "edges";
      svg.setAttribute("width", atlas.width);
      svg.setAttribute("height", atlas.height);
      const defs = document.createElementNS(SVG, "defs");
      for (const [name, color] of [["plain", "--line"], ["on", "--tint"]]) {
        const marker = document.createElementNS(SVG, "marker");
        marker.id = "arrow-" + name;
        for (const [key, value] of [["viewBox", "0 0 10 10"], ["refX", "9"], ["refY", "5"], ["markerWidth", "8"], ["markerHeight", "8"], ["markerUnits", "userSpaceOnUse"], ["orient", "auto"]]) {
          marker.setAttribute(key, value);
        }
        const head = document.createElementNS(SVG, "path");
        head.setAttribute("d", "M1 1.5L9 5L1 8.5");
        head.setAttribute("fill", "none");
        head.setAttribute("stroke-width", "1.6");
        head.setAttribute("stroke-linecap", "round");
        head.setAttribute("stroke-linejoin", "round");
        head.style.stroke = "var(" + color + ")";
        marker.append(head);
        defs.append(marker);
      }
      svg.append(defs);
      for (const edge of atlas.edges) {
        const style = edge.isBack ? "back" : edge.kind;
        const path = document.createElementNS(SVG, "path");
        path.setAttribute("d", edge.d);
        path.setAttribute("class", "edge " + style);
        path.setAttribute("marker-end", "url(#arrow-plain)");
        svg.append(path);
        let dot = null, spot = null;
        if (edge.originX !== undefined) {
          dot = document.createElementNS(SVG, "circle");
          dot.setAttribute("cx", edge.originX);
          dot.setAttribute("cy", edge.originY);
          dot.setAttribute("r", "3.5");
          dot.setAttribute("class", "origin");
          svg.append(dot);
          spot = element("div", "spot");
          spot.style.left = edge.spotX + "px";
          spot.style.top = edge.spotY + "px";
          spot.style.width = edge.spotWidth + "px";
          spot.style.height = edge.spotHeight + "px";
        }
        let pill = null;
        if (edge.label) {
          pill = element("div", "pill", edge.label);
          pill.style.left = edge.labelX + "px";
          pill.style.top = edge.labelY + "px";
        }
        edgeViews.push({ edge, path, pill, dot, spot });
      }
      world.append(svg);
      for (const { pill, spot } of edgeViews) {
        if (spot) world.append(spot);
        if (pill) world.append(pill);
      }
    }

    function drawCards() {
      for (const node of atlas.nodes) {
        const card = element("button", "card" + (node.status === "ok" ? "" : " problem"));
        card.style.left = node.x + "px";
        card.style.top = node.y + "px";
        card.style.width = atlas.cardWidth + "px";
        card.setAttribute("aria-label", node.title);
        const phone = element("span", "phone");
        phone.style.height = atlas.phoneHeight + "px";
        if (node.image) {
          const image = element("img");
          image.src = node.image;
          image.alt = "";
          image.draggable = false;
          phone.append(image);
        }
        if (node.heading) {
          const veil = element("span", "veil");
          veil.append(element("strong", "", node.heading), element("span", "", node.note || ""));
          phone.append(veil);
        }
        card.append(phone, element("span", "title", node.title));
        card.addEventListener("click", event => {
          // The end of a drag across the map isn't a click on whatever it ended over.
          if (dragDistance > 4) { event.preventDefault(); return; }
          select(node.id);
        });
        cards.set(node.id, card);
        world.append(card);
      }
    }

    function drawSidebar() {
      const areas = new Map();
      for (const node of atlas.nodes) {
        const area = (node.group || "Screens").split("/")[0];
        if (!areas.has(area)) areas.set(area, []);
        areas.get(area).push(node);
      }
      for (const [area, nodes] of areas) {
        const heading = element("h4", "", area);
        sidebarAreas.push({ heading, ids: nodes.map(node => node.id) });
        sidebar.append(heading);
        for (const node of nodes) {
          const row = element("button");
          row.append(element("span", "", node.title));
          if (node.status !== "ok") row.append(element("span", "mark"));
          row.addEventListener("click", () => select(node.id));
          sidebarRows.set(node.id, row);
          sidebar.append(row);
        }
      }
    }

    // MARK: The view

    function applyView(flying) {
      world.classList.toggle("flying", !!flying);
      world.style.transform = "translate(" + view.x + "px," + view.y + "px) scale(" + view.k + ")";
    }

    /// What's left for the map once the sidebar, toolbar and inspector have their room.
    function chrome() {
      const inspector = panel.classList.contains("open") && innerWidth > 720 ? panel.offsetWidth : 0;
      return { left: sidebar.offsetWidth, right: inspector, top: 52, bottom: 0 };
    }

    function fit(flying = true) {
      const edges = chrome(), pad = 24;
      const width = innerWidth - edges.left - edges.right - pad * 2;
      const height = innerHeight - edges.top - edges.bottom - pad;
      const k = Math.min(width / atlas.width, height / atlas.height, 1);
      view = {
        k,
        x: edges.left + pad + (width - atlas.width * k) / 2,
        y: edges.top + Math.max(0, (height - atlas.height * k) / 2),
      };
      applyView(flying);
    }

    function zoom(factor, cx, cy) {
      const k = Math.min(2.5, Math.max(.08, view.k * factor));
      const scale = k / view.k;
      view = { k, x: cx - (cx - view.x) * scale, y: cy - (cy - view.y) * scale };
      applyView(false);
    }

    /// Brings a screen into view without moving the map if it's already there,
    /// so stepping through a row doesn't make the whole chart lurch each time.
    function reveal(node) {
      const edges = chrome();
      const k = Math.max(view.k, .55);
      const width = atlas.cardWidth * k, height = (atlas.phoneHeight + 30) * k;
      const left = node.x * k + view.x, top = node.y * k + view.y;
      const right = innerWidth - edges.right, bottom = innerHeight - edges.bottom;
      const fits = view.k >= .55 && left >= edges.left + 16 && top >= edges.top && left + width <= right - 16 && top + height <= bottom - 8;
      if (fits) return;
      view = {
        k,
        x: edges.left + (right - edges.left - width) / 2 - node.x * k,
        y: Math.max(edges.top + 12, edges.top + (bottom - edges.top - height) / 2) - node.y * k,
      };
      applyView(true);
    }

    // MARK: Selecting

    function connectedTo(id) {
      const ids = new Set([id]);
      for (const { edge } of edgeViews) {
        if (edge.from === id) ids.add(edge.to);
        if (edge.to === id) ids.add(edge.from);
      }
      return ids;
    }

    function paint() {
      const query = search.value.trim().toLowerCase();
      const near = selected ? connectedTo(selected) : null;
      for (const [id, card] of cards) {
        const node = nodesById.get(id);
        const found = !query || node.title.toLowerCase().includes(query) || id.toLowerCase().includes(query);
        card.classList.toggle("dim", !found || (near !== null && !near.has(id)));
        card.classList.toggle("selected", id === selected);
        sidebarRows.get(id).classList.toggle("selected", id === selected);
        sidebarRows.get(id).hidden = !found;
      }
      for (const { heading, ids } of sidebarAreas) {
        heading.hidden = ids.every(id => sidebarRows.get(id).hidden);
      }
      for (const { edge, path, pill, dot, spot } of edgeViews) {
        const on = !!selected && (edge.from === selected || edge.to === selected);
        const off = (!!selected && !on) || !!query;
        path.classList.toggle("on", on);
        path.classList.toggle("dim", off);
        path.setAttribute("marker-end", on ? "url(#arrow-on)" : "url(#arrow-plain)");
        if (dot) {
          dot.classList.toggle("on", on);
          dot.classList.toggle("dim", off);
          // Only the selected screen's own ways out light up its elements.
          spot.classList.toggle("on", !!selected && edge.from === selected);
        }
        if (pill) {
          pill.classList.toggle("on", on);
          pill.classList.toggle("dim", off);
        }
      }
    }

    function select(id) {
      selected = id;
      if (id === null) {
        panel.classList.remove("open");
        setAddress(location.pathname + location.search);
      } else {
        const node = nodesById.get(id);
        if (!node) return;
        renderPanel(node);
        panel.classList.add("open");
        panel.scrollTop = 0;
        setAddress(location.pathname + location.search + "#" + encodeURIComponent(id));
        reveal(node);
        sidebarRows.get(id).scrollIntoView({ block: "nearest" });
      }
      paint();
    }

    function step(by) {
      const ids = atlas.nodes.map(node => node.id);
      const at = selected === null ? (by > 0 ? -1 : 0) : ids.indexOf(selected);
      select(ids[(at + by + ids.length) % ids.length]);
    }

    // MARK: The inspector

    function section(heading, rows) {
      if (!rows.length) return [];
      const list = element("ul", "group");
      for (const row of rows) {
        const item = element("li");
        item.append(row);
        list.append(item);
      }
      return [element("h3", "", heading), list];
    }

    function linkRows(edges, targetOf) {
      return edges.flatMap(edge => {
        const target = nodesById.get(targetOf(edge));
        if (!target) return [];
        const row = element("button", "row");
        row.append(element("span", "grow", target.title));
        const words = [edge.label, edge.isBack ? "back" : edge.kind === "push" ? null : edge.kind === "cover" ? "full screen" : edge.kind];
        const detail = words.filter(Boolean).join(" · ");
        if (detail) row.append(element("small", "", detail));
        row.title = edge.source ? edge.raw + "\n" + edge.source : "From the config";
        row.addEventListener("click", () => select(target.id));
        return [row];
      });
    }

    function valueRow(name, value) {
      const row = element("div", "row");
      row.append(element("span", "", name), element("code", "", value));
      return row;
    }

    function renderPanel(node) {
      panel.replaceChildren();
      const ids = atlas.nodes.map(item => item.id);
      const header = element("header");
      header.append(element("h2", "", node.title));
      for (const [text, label, action] of [["‹", "Previous screen", () => step(-1)], ["›", "Next screen", () => step(1)], ["×", "Close", () => select(null)]]) {
        const button = element("button", "round", text);
        button.setAttribute("aria-label", label);
        button.addEventListener("click", action);
        header.append(button);
      }
      panel.append(header, element("p", "position", (ids.indexOf(node.id) + 1) + " of " + ids.length));

      if (node.heading) {
        const note = element("div", "problem-note");
        note.append(element("strong", "", node.heading), element("span", "", node.note || ""));
        panel.append(note);
      }
      if (node.image) {
        const shot = element("img", "shot");
        shot.src = node.image;
        shot.alt = node.status === "ok" ? "Screenshot of " + node.title : "Where the capture of " + node.title + " stopped";
        panel.append(shot);
      }

      const stepRows = (node.steps || []).map((text, index) => {
        const row = element("div", "row");
        row.append(element("span", "number", String(index + 1)), element("span", "grow", text));
        return row;
      });
      panel.append(...section("How to get here", stepRows));
      panel.append(...section("Goes to", linkRows(atlas.edges.filter(edge => edge.from === node.id), edge => edge.to)));
      panel.append(...section("Comes from", linkRows(atlas.edges.filter(edge => edge.to === node.id), edge => edge.from)));
      const details = [valueRow("View", node.id)];
      if (node.source) details.push(valueRow("Source", node.source));
      panel.append(...section("Details", details));

      if (node.labels && node.labels.length) {
        const more = element("details");
        more.open = true;
        more.append(element("summary", "", "What was on screen when it stopped"), element("p", "", node.labels.join(" · ")));
        panel.append(more);
      }
      const gaps = atlas.gaps.filter(gap => gap.screen === node.id);
      if (gaps.length) {
        const more = element("details");
        more.append(element("summary", "", gaps.length + " link" + (gaps.length === 1 ? "" : "s") + " the scan couldn't follow"));
        const list = element("ul");
        for (const gap of gaps) {
          const row = element("li");
          row.append(element("code", "", gap.raw + "  " + gap.source));
          list.append(row);
        }
        more.append(list);
        panel.append(more);
      }
    }

    // MARK: Input

    let drag = null;
    let dragDistance = 0;
    canvas.addEventListener("pointerdown", event => {
      if (event.button !== 0) return;
      drag = { px: event.clientX, py: event.clientY, x: view.x, y: view.y };
      dragDistance = 0;
    });
    addEventListener("pointermove", event => {
      if (!drag) return;
      const dx = event.clientX - drag.px, dy = event.clientY - drag.py;
      dragDistance = Math.max(dragDistance, Math.hypot(dx, dy));
      if (dragDistance > 4) canvas.classList.add("dragging");
      view = { ...view, x: drag.x + dx, y: drag.y + dy };
      applyView(false);
    });
    addEventListener("pointerup", () => { drag = null; canvas.classList.remove("dragging"); });
    addEventListener("resize", () => fit(false));
    // The window can settle on its size after this script runs, so fit again once it has.
    addEventListener("load", () => { if (selected === null) fit(false); });
    canvas.addEventListener("click", event => {
      if (dragDistance <= 4 && !event.target.closest(".card")) select(null);
    });
    canvas.addEventListener("wheel", event => {
      event.preventDefault();
      // A pinch arrives as a wheel event with ctrl held; a two-finger scroll, without.
      if (event.ctrlKey || event.metaKey) {
        zoom(Math.exp(-event.deltaY * .01), event.clientX, event.clientY);
      } else {
        view = { ...view, x: view.x - event.deltaX, y: view.y - event.deltaY };
        applyView(false);
      }
    }, { passive: false });

    document.getElementById("zoom-in").addEventListener("click", () => zoom(1.25, innerWidth / 2, innerHeight / 2));
    document.getElementById("zoom-out").addEventListener("click", () => zoom(.8, innerWidth / 2, innerHeight / 2));
    document.getElementById("fit").addEventListener("click", () => fit());
    document.getElementById("start").addEventListener("click", () => step(1));
    search.addEventListener("input", paint);
    search.addEventListener("keydown", event => {
      if (event.key === "Enter") {
        const query = search.value.trim().toLowerCase();
        const match = atlas.nodes.find(node => node.title.toLowerCase().includes(query) || node.id.toLowerCase().includes(query));
        if (match) select(match.id);
      } else if (event.key === "Escape") {
        search.value = "";
        search.blur();
        paint();
      }
    });
    addEventListener("keydown", event => {
      if (event.target === search || event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.key === "j" || event.key === "ArrowRight") step(1);
      else if (event.key === "k" || event.key === "ArrowLeft") step(-1);
      else if (event.key === "f") fit();
      else if (event.key === "+" || event.key === "=") zoom(1.25, innerWidth / 2, innerHeight / 2);
      else if (event.key === "-") zoom(.8, innerWidth / 2, innerHeight / 2);
      else if (event.key === "Escape") select(null);
      else if (event.key === "/") { event.preventDefault(); search.focus(); }
    });

    // MARK: Start

    document.querySelector("#summary h1").textContent = atlas.name;
    document.querySelector("#summary p").textContent = atlas.details.join(" · ");
    drawLegend();
    // Cards first: an arrow starting on a screen has to be drawn over its screenshot.
    drawCards();
    drawEdges();
    drawSidebar();
    // No animation on the way in: the map should simply be there when the page opens.
    fit(false);
    const linked = decodeURIComponent(location.hash.slice(1));
    if (nodesById.has(linked)) select(linked);
    paint();
    </script>
    </body>
    </html>
    """#
}
