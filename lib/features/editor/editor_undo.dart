// 编辑器撤销/重做历史（从页面抽出）

/// 容量受限的撤销/重做双栈：push 新快照清空重做栈（新编辑分叉），
/// undo/redo 时把「当前状态」压入对侧栈并弹出本侧栈顶
class SnapshotHistory<T> {
  final int max;

  ///< 栈容量上限（超出丢最旧）
  final List<T> _undoStack = [];
  final List<T> _redoStack = [];

  SnapshotHistory({this.max = 50});

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 记录一次编辑前的快照
  void push(T snapshot) {
    _undoStack.add(snapshot);
    if (_undoStack.length > max) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// 撤销：弹出撤销栈顶（[current] 为当前状态，压入重做栈）；无可撤销返回 null
  T? undo(T current) {
    if (_undoStack.isEmpty) {
      return null;
    }
    _redoStack.add(current);
    return _undoStack.removeLast();
  }

  /// 重做：弹出重做栈顶（[current] 压入撤销栈）；无可重做返回 null
  T? redo(T current) {
    if (_redoStack.isEmpty) {
      return null;
    }
    _undoStack.add(current);
    return _redoStack.removeLast();
  }
}
