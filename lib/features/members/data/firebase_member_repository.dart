import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../../../cores/errors/app_exception.dart';
import '../../../cores/firebase/firebase_guard.dart';
import '../../../shared/policies/member_policy.dart';
import '../../../shared/policies/policy_guard.dart';
import '../../../shared/role/role.dart';
import '../../../shared/session/session.dart';
import '../domain/member.dart';
import '../domain/member_repository.dart';

typedef _Doc = DocumentSnapshot<Map<String, dynamic>>;

/// Anggota di Firestore: `families/{familyId}/members/{memberId}`.
/// Disimpan di cache agar getter sinkron (byId, nameOf, ...) tetap jalan.
/// Aturan: fungsi `load*` TIDAK memanggil notifyListeners (agar AsyncBuilder tidak loop);
/// hanya perubahan data (create/update/delete/...) yang memanggilnya.
class FirebaseMemberRepository extends ChangeNotifier implements MemberRepository {
  FirebaseMemberRepository({required Session session, FirebaseFirestore? db})
      : _session = session,
        _db = db ?? FirebaseFirestore.instance;

  final Session _session;
  final FirebaseFirestore _db;
  final List<Member> _items = [];

  String? get _familyId => _session.familyId;
  List<Member> get _scoped => [for (final m in _items) if (m.familyId == _familyId) m];

  CollectionReference<Map<String, dynamic>> _col(String fid) =>
      _db.collection('families').doc(fid).collection('members');

  DocumentReference<Map<String, dynamic>> _family(String fid) => _db.collection('families').doc(fid);

  void _requireManage() => requireAllowed(MemberPolicy.canManage(_session.role));

  static Member _fromDoc(String fid, _Doc d) {
    final m = d.data()!;
    return Member(
      id: d.id,
      familyId: fid,
      name: m['name'] as String,
      email: m['email'] as String,
      role: Role.values.byName(m['role'] as String),
      userId: m['userId'] as String?,
    );
  }

  /// Muat anggota dari semua keluarga yang diberikan (cache diganti seluruhnya). Tanpa notify.
  Future<void> loadForFamilies(List<String> familyIds) async {
    final results = await firebaseCall(
      () => Future.wait([for (final id in familyIds) _col(id).orderBy('createdAt').get()]),
    );
    _items.clear();
    for (var i = 0; i < familyIds.length; i++) {
      _items.addAll(results[i].docs.map((d) => _fromDoc(familyIds[i], d)));
    }
  }

  /// Kosongkan cache (saat keluar). Tanpa notify.
  void clear() => _items.clear();

  @override
  List<Member> get snapshot => List<Member>.unmodifiable(_scoped);

  @override
  Member? byId(String id) {
    for (final m in _items) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  String nameOf(String id) => byId(id)?.name ?? Member.removedName;

  @override
  bool isMember(String familyId, String userId) =>
      _items.any((m) => m.familyId == familyId && m.userId == userId);

  @override
  int adminCountIn(String familyId) => _items.where((m) => m.familyId == familyId && m.role == Role.admin).length;

  @override
  int countIn(String familyId) => _items.where((m) => m.familyId == familyId).length;

  @override
  Member? memberOfUser(String familyId, String userId) {
    for (final m in _items) {
      if (m.familyId == familyId && m.userId == userId) return m;
    }
    return null;
  }

  @override
  Future<List<Member>> loadMembers() async {
    final fid = _familyId;
    if (fid == null) return <Member>[];
    final snap = await firebaseCall(() => _col(fid).orderBy('createdAt').get());
    _items
      ..removeWhere((m) => m.familyId == fid)
      ..addAll(snap.docs.map((d) => _fromDoc(fid, d)));
    return _scoped;
  }

  @override
  Future<Member> loadMember(String id) async {
    final fid = _familyId;
    final doc = fid == null ? null : await firebaseCall(() => _col(fid).doc(id).get());
    if (fid == null || doc == null || !doc.exists) {
      throw NotFoundException('Anggota dengan ID "$id" tidak ditemukan.');
    }
    final m = _fromDoc(fid, doc);
    _replace(m);
    return m;
  }

  void _replace(Member m) {
    final i = _items.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      _items[i] = m;
    } else {
      _items.add(m);
    }
  }

  void _ensureRoleChangeAllowed(Member current, Role newRole) {
    if (newRole == Role.admin && current.userId == null) {
      throw const AppException('Anggota yang belum punya akun belum bisa dijadikan admin.');
    }
    final allowed = MemberPolicy.canChangeRole(
      current: current.role,
      next: newRole,
      adminCount: adminCountIn(current.familyId),
    );
    if (!allowed) {
      throw const AppException('Keluarga harus punya minimal 1 admin. Jadikan anggota lain admin dulu.');
    }
  }

  @override
  Future<Member> create(Member draft) async {
    _requireManage();
    final fid = _familyId ?? draft.familyId;
    if (draft.role == Role.admin) {
      throw const AppException('Anggota yang belum punya akun belum bisa dijadikan admin.');
    }
    final email = draft.email.trim().toLowerCase();
    final ref = _col(fid).doc();
    await firebaseCall(() async {
      final dup = await _col(fid).where('email', isEqualTo: email).limit(1).get();
      if (dup.docs.isNotEmpty) throw AppException('Email $email sudah terdaftar sebagai anggota.');
      await ref.set({
        'name': draft.name.trim(),
        'email': email,
        'role': Role.member.name,
        'userId': null,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
    final m = Member(id: ref.id, familyId: fid, name: draft.name.trim(), email: email, role: Role.member);
    _items.add(m);
    notifyListeners();
    return m;
  }

  @override
  Future<Member> update(Member member) async {
    final current = byId(member.id);
    if (current == null) throw NotFoundException('Anggota dengan ID "${member.id}" tidak ditemukan.');
    _requireManage();
    _ensureRoleChangeAllowed(current, member.role);
    final email = member.email.trim().toLowerCase();
    await firebaseCall(() async {
      final batch = _db.batch();
      batch.update(_col(current.familyId).doc(current.id), {
        'name': member.name.trim(),
        'email': email,
        'role': member.role.name,
      });
      if (current.userId != null && member.role != current.role) {
        batch.update(_family(current.familyId), {
          'adminUids': member.role == Role.admin
              ? FieldValue.arrayUnion([current.userId])
              : FieldValue.arrayRemove([current.userId]),
        });
      }
      await batch.commit();
    });
    final updated = current.copyWith(name: member.name.trim(), email: email, role: member.role);
    _replace(updated);
    notifyListeners();
    return updated;
  }

  @override
  Future<void> delete(String id) async {
    _requireManage();
    final target = byId(id);
    if (target == null) throw NotFoundException('Anggota dengan ID "$id" tidak ditemukan.');
    if (!MemberPolicy.canDelete(target: target.role, adminCount: adminCountIn(target.familyId))) {
      throw const AppException('Admin terakhir tidak dapat dihapus. Jadikan anggota lain admin dulu.');
    }
    await firebaseCall(() async {
      // Cek langsung ke database (cache chore bisa belum lengkap).
      final pending = await _col(target.familyId)
          .parent!
          .collection('chores')
          .where('assigneeId', isEqualTo: id)
          .where('isCompleted', isEqualTo: false)
          .get();
      if (pending.docs.isNotEmpty) {
        throw AppException(
            'Anggota masih memiliki ${pending.docs.length} chore aktif. Pindahkan atau selesaikan chore tersebut dulu.');
      }
      final batch = _db.batch();
      batch.delete(_col(target.familyId).doc(id));
      if (target.userId != null) {
        batch.update(_family(target.familyId), {
          'memberUids': FieldValue.arrayRemove([target.userId]),
          'adminUids': FieldValue.arrayRemove([target.userId]),
        });
      }
      await batch.commit();
    });
    _items.removeWhere((m) => m.id == id);
    notifyListeners();
  }

  @override
  Future<Member> setAdmin(String id, {required bool admin}) async {
    final current = byId(id);
    if (current == null) throw NotFoundException('Anggota dengan ID "$id" tidak ditemukan.');
    _requireManage();
    final newRole = admin ? Role.admin : Role.member;
    _ensureRoleChangeAllowed(current, newRole);
    if (newRole == current.role) return current;
    await firebaseCall(() async {
      final batch = _db.batch();
      batch.update(_col(current.familyId).doc(id), {'role': newRole.name});
      if (current.userId != null) {
        batch.update(_family(current.familyId), {
          'adminUids': admin ? FieldValue.arrayUnion([current.userId]) : FieldValue.arrayRemove([current.userId]),
        });
      }
      await batch.commit();
    });
    final updated = current.copyWith(role: newRole);
    _replace(updated);
    notifyListeners();
    return updated;
  }

  /// Samakan nama di semua keluarga (cache + Firestore). Di-await oleh AuthController.
  @override
  Future<void> syncUserName(String userId, String name) async {
    final mine = _items.where((m) => m.userId == userId).toList();
    if (mine.isEmpty) return;
    await firebaseCall(() async {
      final batch = _db.batch();
      for (final m in mine) {
        batch.update(_col(m.familyId).doc(m.id), {'name': name});
      }
      await batch.commit();
    });
    for (final m in mine) {
      _replace(m.copyWith(name: name));
    }
    notifyListeners();
  }

  // Di Firebase, buat/gabung keluarga dilakukan FirebaseFamilyRepository (batch write).
  @override
  Member joinAsMember({required String familyId, required SessionUser user}) =>
      throw UnsupportedError('Gunakan FamilyRepository.join.');

  @override
  Member addForUser({required String familyId, required SessionUser user, Role role = Role.admin}) =>
      throw UnsupportedError('Gunakan FamilyRepository.create.');
}
