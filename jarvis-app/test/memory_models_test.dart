import 'package:jarvis_app/src/core/memory/memory_models.dart';
import 'package:jarvis_app/src/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageSource 兼容性', () {
    test('老数据缺 kind 时默认 web', () {
      final source = MessageSource.fromJson(<String, dynamic>{
        'url': 'https://example.com',
        'fetched_at': 1_700_000_000_000,
      });

      expect(source.kind, MessageSourceKind.web);
      expect(source.memoryId, isNull);
      expect(source.isMemory, isFalse);
      expect(source.host, 'example.com');
    });

    test('未知 kind 回退 web 而不是抛异常', () {
      final source = MessageSource.fromJson(<String, dynamic>{
        'url': 'https://example.com',
        'fetched_at': 1,
        'kind': 'hologram',
      });

      expect(source.kind, MessageSourceKind.web);
    });

    test('记忆来源带 memory_id 且可点开', () {
      final source = MessageSource.fromJson(<String, dynamic>{
        'url': 'memory://mem_1',
        'fetched_at': 1,
        'kind': 'memory',
        'memory_id': 'mem_1',
      });

      expect(source.kind, MessageSourceKind.memory);
      expect(source.memoryId, 'mem_1');
      expect(source.canOpen, isTrue);
      expect(source.host, '来自记忆');
    });

    test('memory_id 缺失时不可点（降级为纯文本）', () {
      final source = MessageSource.fromJson(<String, dynamic>{
        'url': 'memory://mem_1',
        'fetched_at': 1,
        'kind': 'memory',
      });

      expect(source.isMemory, isTrue);
      expect(source.canOpen, isFalse);
    });

    test('fetched_at 是 double 也能解析', () {
      final source = MessageSource.fromJson(<String, dynamic>{
        'url': 'https://example.com',
        'fetched_at': 1700000000000.0,
      });

      expect(source.fetchedAt, 1700000000000);
    });
  });

  group('记忆模型', () {
    test('Memory 缺可选字段时不崩', () {
      final memory = Memory.fromJson(<String, dynamic>{
        'id': 'mem_1',
        'kind': 'preference',
        'status': 'active',
        'content': '回答先给结论',
        'source': 'explicit',
      });

      expect(memory.kind, MemoryKind.preference);
      expect(memory.status, MemoryStatus.active);
      expect(memory.pinned, isFalse);
      expect(memory.conflicting, isFalse);
      expect(memory.isPrivate, isFalse);
      expect(memory.timeScope, isNull);
      expect(memory.metaLine, contains('偏好'));
    });

    test('未知枚举回退到保守值', () {
      expect(MemoryKind.parse('unknown'), MemoryKind.event);
      expect(MemoryStatus.parse('unknown'), MemoryStatus.archived);
      expect(MemorySensitivity.parse('unknown'), MemorySensitivity.normal);
    });

    test('私密记忆被识别', () {
      final memory = Memory.fromJson(<String, dynamic>{
        'id': 'mem_2',
        'kind': 'profile',
        'status': 'active',
        'content': '每月房贷',
        'source': 'explicit',
        'sensitivity': 'private',
      });

      expect(memory.isPrivate, isTrue);
    });

    test('MemoryDetail 解析证据与召回次数', () {
      final detail = MemoryDetail.fromJson(<String, dynamic>{
        'memory': <String, dynamic>{
          'id': 'mem_1',
          'kind': 'preference',
          'status': 'active',
          'content': '回答先给结论',
          'source': 'explicit',
        },
        'evidence': <dynamic>[
          <String, dynamic>{
            'id': 'ev_1',
            'source_kind': 'explicit',
            'source_id': 'bat_1',
            'quote': '以后回答先给结论',
            'support_span': '先给结论',
            'created_at': 1,
          },
        ],
        'recall_count': 3,
      });

      expect(detail.evidence, hasLength(1));
      expect(detail.evidence.first.hasHighlight, isTrue);
      expect(detail.recallCount, 3);
    });

    test('support_span 与 quote 相同则不高亮', () {
      const evidence = MemoryEvidence(
        id: 'ev_1',
        sourceKind: EvidenceSourceKind.explicit,
        sourceId: 'bat_1',
        quote: '不吃香菜',
        supportSpan: '不吃香菜',
        createdAt: 1,
      );

      expect(evidence.hasHighlight, isFalse);
    });

    test('状态快照能读出告警与额度', () {
      final state = MemoryStateView.fromJson(<String, dynamic>{
        'enabled': true,
        'counts': <String, dynamic>{'active': 2, 'candidate': 1},
        'digest': <String, dynamic>{'chars': 120, 'memory_items': 2},
        'extract': <String, dynamic>{
          'enabled': false,
          'daily_limit': 50,
          'used_today': 3,
        },
        'heartbeat': <String, dynamic>{'enabled': false, 'daily_limit': 2},
        'digest_warning': '置顶记忆共 320 字，超过摘要预算 300 字',
      });

      expect(state.enabled, isTrue);
      expect(state.counts.active, 2);
      expect(state.counts.candidate, 1);
      expect(state.digest.chars, 120);
      expect(state.extract.usedToday, 3);
      expect(state.digestWarning, contains('置顶'));
    });

    test('formatDate 只到天', () {
      final millis = DateTime(2026, 10, 29, 13, 5).millisecondsSinceEpoch;
      expect(formatDate(millis), '2026-10-29');
      expect(formatDate(0), '时间未知');
    });
  });
}
