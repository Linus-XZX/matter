sealed class MatrixHtmlNode {
  const MatrixHtmlNode();

  String get textContent;
}

class MatrixTextNode extends MatrixHtmlNode {
  final String text;

  const MatrixTextNode(this.text);

  @override
  String get textContent => text;
}

class MatrixElementNode extends MatrixHtmlNode {
  final String tag;
  final List<MatrixHtmlNode> children;
  final Map<String, String> attributes;

  const MatrixElementNode({
    required this.tag,
    required this.children,
    this.attributes = const {},
  });

  @override
  String get textContent => children.map((child) => child.textContent).join();
}
