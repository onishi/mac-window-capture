import ApplicationServices
import CoreGraphics

/// ウィンドウの各辺から削る量 (ポイント)。
/// 割合ではなく辺からの距離で持つので、ウィンドウをリサイズしてもタイトルバーやツールバーの分だけ削れる。
nonisolated struct CropInsets: Codable, Equatable, Sendable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    static let zero = CropInsets(top: 0, left: 0, bottom: 0, right: 0)

    /// ウィンドウ内の矩形 (左上原点、ポイント) から作る
    init(rect: CGRect, in size: CGSize) {
        let rect = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        top = rect.minY
        left = rect.minX
        bottom = size.height - rect.maxY
        right = size.width - rect.maxX
    }

    init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// 指定サイズのウィンドウで残す矩形 (左上原点、ポイント)。削りすぎて潰れる場合は nil。
    func rect(in size: CGSize) -> CGRect? {
        // CGRect の width/height は負の値を絶対値で返すので、矩形にする前に判定する
        let width = size.width - left - right
        let height = size.height - top - bottom
        guard width >= 1, height >= 1 else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    /// 画像を切り出す。scale は 1 ポイントあたりのピクセル数。
    func crop(_ image: CGImage, scale: CGFloat) -> CGImage {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let rect = rect(in: size) else { return image }
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: pixelRect) ?? image
    }
}

/// アクセシビリティ API でウィンドウの「中身」の領域を推定する。
///
/// 1. 中身の候補を決める: Web ページ部分 → スクロール領域 → 子を持たない大きな要素 (独自描画の本文など) → ウィンドウ全体の順
/// 2. 候補に重なっている操作部品 (ボタン・見出し・テキスト・ツールバーなど、候補の子孫は除く) を避けた最大の長方形を中身とする
enum ContentAreaDetector {
    /// AX ツリーの 1 要素。frame はウィンドウ左上原点のポイント
    struct Node {
        var role: String
        var frame: CGRect
        var parent: Int?
        var hasChildren: Bool
    }

    /// 中身とみなす役割。前にあるものほど優先する。
    private nonisolated static let contentRoles = ["AXWebArea", "AXScrollArea"]
    /// 中身に重なっていたら避ける操作部品の役割
    private nonisolated static let chromeRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXRadioGroup",
        "AXTextField", "AXSearchField", "AXComboBox", "AXSlider", "AXStaticText", "AXHeading",
        "AXToolbar", "AXTabGroup", "AXSegmentedControl", "AXDisclosureTriangle", "AXIncrementor",
    ]
    /// 子を持たない要素を中身の候補にするときの、ウィンドウ面積に対する最小割合
    private nonisolated static let minimumLeafAreaRatio = 0.25
    private static let maxVisitedElements = 3000

    /// ウィンドウ内の中身の矩形 (ウィンドウ左上原点、ポイント)。AX ウィンドウが見つからなければ nil。
    static func detect(in window: WindowInfo) -> CGRect? {
        guard let root = AX.window(matching: window) else { return nil }
        return detect(windowElement: root, windowFrame: window.frame)
    }

    static func detect(windowElement: AXUIElement, windowFrame: CGRect) -> CGRect? {
        contentArea(nodes: collectNodes(root: windowElement, windowFrame: windowFrame), windowSize: windowFrame.size)
    }

    nonisolated static func contentArea(nodes: [Node], windowSize: CGSize) -> CGRect? {
        let windowRect = CGRect(origin: .zero, size: windowSize)
        let usable = nodes.indices.filter { nodes[$0].frame.width >= 1 && nodes[$0].frame.height >= 1 }

        let containerIndex: Int? = contentRoles.lazy.compactMap { role in
            usable.filter { nodes[$0].role == role && nodes[$0].frame.width >= 50 && nodes[$0].frame.height >= 50 }
                .max { nodes[$0].frame.area < nodes[$1].frame.area }
        }.first ?? usable.filter { index in
            let node = nodes[index]
            return !node.hasChildren && !chromeRoles.contains(node.role)
                && node.frame.area >= windowRect.area * minimumLeafAreaRatio
        }.max { nodes[$0].frame.area < nodes[$1].frame.area }

        let container = containerIndex.map { nodes[$0].frame } ?? windowRect
        let obstacles = usable.filter { index in
            chromeRoles.contains(nodes[index].role) && !isDescendant(index, of: containerIndex, in: nodes)
        }.map { nodes[$0].frame }
        return largestEmptyRect(in: container, avoiding: obstacles)
    }

    /// container の中で、どの障害物とも重ならない最大面積の長方形。
    /// 候補の辺は container と障害物の辺に限られるので、それらの組み合わせを総当たりする。
    nonisolated static func largestEmptyRect(in container: CGRect, avoiding obstacles: [CGRect]) -> CGRect? {
        let blockers = obstacles
            .map { $0.intersection(container) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !blockers.isEmpty else { return container }

        let xs = Set([container.minX, container.maxX] + blockers.flatMap { [$0.minX, $0.maxX] }).sorted()
        let ys = Set([container.minY, container.maxY] + blockers.flatMap { [$0.minY, $0.maxY] }).sorted()
        var best: CGRect?
        for (i, left) in xs.enumerated() {
            for right in xs[(i + 1)...] {
                // この幅で縦に区切る障害物だけを見る
                let columnBlockers = blockers.filter { $0.minX < right && $0.maxX > left }
                for (j, top) in ys.enumerated() {
                    for bottom in ys[(j + 1)...] {
                        let area = (right - left) * (bottom - top)
                        if let best, area <= best.area { continue }
                        if columnBlockers.contains(where: { $0.minY < bottom && $0.maxY > top }) { break }
                        best = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    }
                }
            }
        }
        return best
    }

    // MARK: - Private

    private nonisolated static func isDescendant(_ index: Int, of ancestor: Int?, in nodes: [Node]) -> Bool {
        guard let ancestor else { return false }
        var current = nodes[index].parent
        while let parent = current {
            if parent == ancestor { return true }
            current = nodes[parent].parent
        }
        return false
    }

    /// AX ツリーを幅優先でたどって要素を集める。Web ページやスクロール領域の中身は見ない (要素数が多く、操作部品も中身の一部なので)
    private static func collectNodes(root: AXUIElement, windowFrame: CGRect) -> [Node] {
        var nodes: [Node] = []
        var queue: [(element: AXUIElement, parent: Int?)] = [(root, nil)]
        var head = 0
        while head < queue.count, nodes.count < maxVisitedElements {
            let (element, parent) = queue[head]
            head += 1
            let role = AX.role(of: element) ?? ""
            let children = contentRoles.contains(role) ? [] : AX.children(of: element)
            let frame = AX.frame(of: element)?.intersection(windowFrame) ?? .null
            nodes.append(Node(
                role: role,
                frame: frame.isNull ? .zero : frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY),
                parent: parent,
                hasChildren: !children.isEmpty
            ))
            let index = nodes.count - 1
            queue.append(contentsOf: children.map { ($0, index) })
        }
        return nodes
    }
}

private extension CGRect {
    nonisolated var area: CGFloat { width * height }
}
