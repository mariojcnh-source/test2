import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../../../cores/errors/app_exception.dart';
import '../../../cores/firebase/firebase_guard.dart';
import '../../../shared/policies/chore_policy.dart';
import '../../../shared/policies/policy_guard.dart';
import '../../../shared/session/session.dart';
import '../../members/members.dart';
import '../domain/chore.dart';
import '../domain/chore_repository.dart';

typedef _Doc = DocumentSnapshot<Map<String, dynamic>>;

/// Chore di Firestore: `families/{familyId}/chores/{choreId}`.
/// Fungsi `load*` tidak memanggil notifyListeners (hindari loop AsyncBuilder).
class FirebaseChoreRepository extends ChangeNotifier implements ChoreRepository {
  FirebaseChoreRepository({required Session session, required MemberLookup members, FirebaseFirestore? db})
      : _session = session,
        _members = members,
        _db = db ?? FirebaseFirestore.instance;

  final Session _session;
  final MemberLookup _members;
  final FirebaseFirestore _db;
  final List<Chore> _items = [];

  String? get _familyId => _session.familyId;
  List<Chore> get _scoped => [for (final c in _items) if (c.familyId == _familyId) c];

  CollectionReference<Map<String, dynamic>> _col(String fid) =>
      _db.collection('families').doc(fid).collection('chores');

  void _requireManage() => requireAllowed(ChorePolicy.canManage(_session.role));

  bool _canComplete(Chore c) => ChorePolicy.canComplete(
        role: _session.role,
        isAssignee: ChorePolicy.isAssignedTo(
          userEmail: _session.user?.email,
          assigneeEmail: _members.byId(c.assigneeId)?.email,
        ),
      );

  static DateTime? _date(Object? v) => v is Timestamp ? v.toDate() : null;

  static Chore _fromDoc(String fid, _Doc d) {
    final m = d.data()!;
    return Chore(
      id: d.id,
      familyId: fid,
      name: m['name'] as String,
      assigneeId: (m['assigneeId'] as String?) ?? '',
      instructions: (m['instructions'] as String?) ?? '',
      scheduledAt: _date(m['scheduledAt'])!,
      isCompleted: (m['isCompleted'] as bool?) ?? false,
      completedAt: _date(m['completedAt']),
    );
  }

  static Map<String, dynamic> _toMap(Chore c) => {
        'name': c.name.trim(),
        'assigneeId': c.assigneeId,
        'instructions': c.instructions,
        'scheduledAt': Timestamp.fromDate(c.scheduledAt),
        'isCompleted': c.isCompleted,
        'completedAt': c.completedAt == null ? null : Timestamp.fromDate(c.completedAt!),
      };

  void _replace(Chore c) {
    final i = _items.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      _items[i] = c;
    } else {
      _items.add(c);
    }
  }

  /// Chore yang sama (nama + anggota + jadwal) tidak boleh dobel.
  Future<void> _ensureNotDuplicate(String fid, Chore c, {String? exceptId}) async {
    final snap = await _col(fid).where('assigneeId', isEqualTo: c.assigneeId).get();
    final dup = snap.docs.any((d) {
      if (d.id == exceptId) return false;
      final other = _fromDoc(fid, d);
      return other.name.toLowerCase() == c.name.trim().toLowerCase() && other.scheduledAt == c.scheduledAt;
    });
    if (dup) throw const AppException('Chore yang sama sudah ada untuk anggota dan jadwal tersebut.');
  }

  /// Kosongkan cache (saat keluar). Tanpa notify.
  void clear() => _items.clear();

  @override
  int get pendingCount => _scoped.where((c) => !c.isCompleted).length;

  @override
  int pendingCountFor(String memberId) =>
      _items.where((c) => !c.isCompleted && c.assigneeId == memberId).length;

  @override
  Future<List<Chore>> loadChores() async {
    final fid = _familyId;
    if (fid == null) return <Chore>[];
    final snap = await firebaseCall(() => _col(fid).orderBy('scheduledAt').get());
    _items
      ..removeWhere((c) => c.familyId == fid)
      ..addAll(snap.docs.map((d) => _fromDoc(fid, d)));
    return _scoped;
  }

  @override
  Future<Chore> loadChore(String id) async {
    final fid = _familyId;
    final doc = fid == null ? null : await firebaseCall(() => _col(fid).doc(id).get());
    if (fid == null || doc == null || !doc.exists) {
      throw NotFoundException('Chore dengan ID "$id" tidak ditemukan.');
    }
    final c = _fromDoc(fid, doc);
    _replace(c);
    return c;
  }

  @override
  Future<Chore> create(Chore draft) async {
    _requireManage();
    final fid = _familyId ?? draft.familyId;
    final ref = _col(fid).doc();
    await firebaseCall(() async {
      await _ensureNotDuplicate(fid, draft);
      await ref.set({..._toMap(draft), 'createdAt': FieldValue.serverTimestamp()});
    });
    final chore = draft.copyWith(id: ref.id, familyId: fid);
    _items.add(chore);
    notifyListeners();
    return chore;
  }

  @override
  Future<Chore> update(Chore chore) async {
    _requireManage();
    final fid = _familyId ?? chore.familyId;
    await firebaseCall(() async {
      await _ensureNotDuplicate(fid, chore, exceptId: chore.id);
      await _col(fid).doc(chore.id).update(_toMap(chore));
    });
    _replace(chore);
    notifyListeners();
    return chore;
  }

  @override
  Future<void> complete(String id) async {
    final fid = _familyId;
    if (fid == null) throw NotFoundException('Chore dengan ID "$id" tidak ditemukan.');
    final i = _items.indexWhere((c) => c.id == id);
    if (i >= 0) {
      requireAllowed(_canComplete(_items[i]), 'Kamu hanya dapat menyelesaikan tugas yang ditugaskan kepadamu.');
      if (_items[i].isCompleted) return; // cegah proses ganda
    }
    await firebaseCall(
      () => _col(fid).doc(id).update({'isCompleted': true, 'completedAt': FieldValue.serverTimestamp()}),
    );
    final j = _items.indexWhere((c) => c.id == id);
    if (j >= 0) _items[j] = _items[j].copyWith(isCompleted: true, completedAt: DateTime.now());
    notifyListeners();
  }

  @override
  Future<void> delete(String id) async {
    _requireManage();
    final fid = _familyId;
    if (fid == null) throw NotFoundException('Chore dengan ID "$id" tidak ditemukan.');
    await firebaseCall(() => _col(fid).doc(id).delete());
    _items.removeWhere((c) => c.id == id);
    notifyListeners();
  }
}
