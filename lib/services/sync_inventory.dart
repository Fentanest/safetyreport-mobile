/// Evidence for a single traversal of the official, offset-based list API.
/// Completeness of a traversal never proves absence from a stable snapshot.
class ListInventory {
  ListInventory(this.declaredTotal, {this.retainIds = true});

  final int declaredTotal;
  final bool retainIds;
  int _received = 0;
  final Set<String> _ids = {};
  final List<String> invalidReasons = [];
  int _nextStart = 1;

  static int readTotal(Map<String, dynamic> data) {
    final total = data['totalCnt'];
    if (total is! num || !total.isFinite || total < 0 || total != total.toInt()) {
      throw const FormatException('목록 totalCnt가 없거나 올바르지 않습니다.');
    }
    if (data['result'] is! List) {
      throw const FormatException('목록 result 배열이 없습니다.');
    }
    if (total == 0 && (data['result'] as List).isNotEmpty) {
      throw const FormatException('빈 목록의 전체 건수가 일치하지 않습니다.');
    }
    return total.toInt();
  }

  List<Map<String, dynamic>> addPage(Map<String, dynamic> data, int start, int end) {
    try {
      if (start != _nextStart || readTotal(data) != declaredTotal) {
        throw const FormatException('목록 범위 또는 전체 건수가 변경되었습니다.');
      }
      final raw = data['result'] as List;
      if (raw.length != end - start + 1) {
        throw const FormatException('목록 페이지의 실제 건수가 요청 범위와 다릅니다.');
      }
      final rows = <Map<String, dynamic>>[];
      final pageIds = <String>{};
      for (final value in raw) {
        if (value is! Map<String, dynamic>) {
          throw const FormatException('목록 항목 형식이 올바르지 않습니다.');
        }
        final id = value['C_NO']?.toString() ?? '';
        if (id.isEmpty || id != id.trim() || !pageIds.add(id) || _ids.contains(id)) {
          throw const FormatException('목록 ID가 없거나 중복되었습니다.');
        }
        rows.add(value);
      }
      if (retainIds) _ids.addAll(pageIds);
      _received += pageIds.length;
      _nextStart = end + 1;
      return rows;
    } on FormatException catch (e) {
      invalidReasons.add(e.message);
      rethrow;
    }
  }

  bool get listComplete => invalidReasons.isEmpty && _received == declaredTotal && _nextStart == declaredTotal + 1;

  /// This endpoint offers no stable inventory token. Never authorize deletion.
  bool get authoritative => false;
}
