/// 网格操作纯函数库：变换 / 降噪 / 换色 / 选区提取
///
/// 全部返回新数据、不修改入参，供编辑器在撤销快照后调用
library;

/// 网格变换结果（旋转会交换宽高，故连同尺寸一起返回）
class GridResult {
  final List<int> grid;
  final int width;
  final int height;

  const GridResult(this.grid, this.width, this.height);
}

/// 最近邻重采样网格到新尺寸（放大/缩小）
GridResult resizeGrid(List<int> grid, int width, int height, int newWidth, int newHeight) {
  final out = List<int>.filled(newWidth * newHeight, -1);
  for (var y = 0; y < newHeight; y++) {
    // 目标格中心反算源坐标
    final sy = (y + 0.5) * height / newHeight - 0.5;
    final cy = sy.round().clamp(0, height - 1);
    for (var x = 0; x < newWidth; x++) {
      final sx = (x + 0.5) * width / newWidth - 0.5;
      final cx = sx.round().clamp(0, width - 1);
      out[y * newWidth + x] = grid[cy * width + cx];
    }
  }
  return GridResult(out, newWidth, newHeight);
}

/// 水平镜像
GridResult flipHorizontal(List<int> grid, int width, int height) {
  final out = List<int>.filled(grid.length, -1);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out[y * width + (width - 1 - x)] = grid[y * width + x];
    }
  }
  return GridResult(out, width, height);
}

/// 垂直镜像
GridResult flipVertical(List<int> grid, int width, int height) {
  final out = List<int>.filled(grid.length, -1);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out[(height - 1 - y) * width + x] = grid[y * width + x];
    }
  }
  return GridResult(out, width, height);
}

/// 顺时针旋转 90°（宽高互换）
GridResult rotate90(List<int> grid, int width, int height) {
  final out = List<int>.filled(grid.length, -1);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // (x,y) -> (height-1-y, x)，新网格宽 = height
      out[x * height + (height - 1 - y)] = grid[y * width + x];
    }
  }
  return GridResult(out, height, width);
}

/// 多数投票降噪：3×3 窗口内取众数替换中心格
///
/// [passes] 迭代次数（1-3，越多越平滑但细节流失越多）；空格(-1)参与投票
List<int> denoiseMajority(List<int> grid, int width, int height, int passes) {
  var current = grid;
  for (var p = 0; p < passes; p++) {
    final next = List<int>.of(current);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final votes = <int, int>{};
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
              continue;
            }
            final v = current[ny * width + nx];
            votes[v] = (votes[v] ?? 0) + 1;
          }
        }
        // 众数（计数并列时保留原值，避免抖动）
        var bestV = current[y * width + x];
        var bestCount = 0;
        votes.forEach((v, count) {
          if (count > bestCount) {
            bestCount = count;
            bestV = v;
          }
        });
        next[y * width + x] = bestV;
      }
    }
    current = next;
  }
  return current;
}

/// 全局换色：把 [from] 全部替换为 [to]（from 可为 -1 空格），返回替换格数
int replaceColor(List<int> grid, int from, int to) {
  var count = 0;
  for (var i = 0; i < grid.length; i++) {
    if (grid[i] == from) {
      grid[i] = to;
      count++;
    }
  }
  return count;
}

/// 提取矩形选区为新网格（行优先拷贝）
GridResult extractSubGrid(List<int> grid, int width, int x, int y, int w, int h) {
  final out = List<int>.filled(w * h, -1);
  for (var row = 0; row < h; row++) {
    for (var col = 0; col < w; col++) {
      out[row * w + col] = grid[(y + row) * width + (x + col)];
    }
  }
  return GridResult(out, w, h);
}
