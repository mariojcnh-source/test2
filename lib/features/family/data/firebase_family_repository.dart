import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../../../cores/errors/app_exception.dart';
import '../../../cores/firebase/firebase_guard.dart';
import '../../../shared/session/session.dart';
import '../../members/members.dart';
import '../domain/family.dart';
import '../domain/family_code.dart';
import '../domain/family_repository.dart';

/// Keluarga di Firestore:
///  - `families/{id}`        : name, code, createdBy, memberUids[], adminUids[]
///  - `familyCodes/{code}`   : familyId, name  (untuk mencari keluarga dari kode undangan)
/// Anggota & chore ada di subkoleksi `members` dan `chores`.
class FirebaseFamilyRepository extends ChangeNotifier implements FamilyRepository {
  FirebaseFamilyRepository({
    required MemberRepository members,
    required Future<void> Function(List<String> familyIds) refreshMembers,
    FirebaseFirestore? db,
  })  : _members = members,
        _refreshMembers = refreshMembers,
        _db = db ?? FirebaseFirestore.instance;

  final MemberRepository _members;
  final Future<void> Function(List<String> familyIds) _refreshMembers;
  final FirebaseFirestore _db;
  final List<Family> _items = [];

  CollectionReference<Map<String, dynamic>> get _families => _db.collection('families');
  CollectionReference<Map<String, dynamic>> get _codes => _db.collection('familyCodes');

  static Family _fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data()!;
    return Family(id: d.id, name: m['name'] as String, code: m['code'] as String);
  }

  Future<void> _fetchFamilies(String userId) async {
    final snap = await firebaseCall(() => _families.where('memberUids', arrayContains: userId).get());
    _items
      ..clear()
      ..addAll(snap.docs.map(_fromDoc));
  }

  Future<void> _reload(String userId) async {
    await _fetchFamilies(userId);
    await _refreshMembers([for (final f in _items) f.id]);
  }

  /// Muat data awal setelah masuk: keluarga + anggota. Dipanggil AuthController.
  Future<void> refresh() async {
    final uid = _currentUid();
    if (uid == null) return;
    await _reload(uid);
    notifyListeners();
  }

  String? _currentUid() => FirebaseAuth.instance.currentUser?.uid;

  /// Kosongkan cache (saat keluar). Tanpa notify.
  void clear() => _items.clear();

  @override
  Family? byId(String? id) {
    if (id == null) return null;
    for (final f in _items) {
      if (f.id == id) return f;
    }
    return null;
  }

  @override
  Family? byCode(String code) {
    final c = FamilyCode.normalize(code);
    for (final f in _items) {
      if (f.code == c) return f;
    }
    return null;
  }

  /// Daftar sudah disaring di server (memberUids berisi uid pengguna).
  @override
  List<Family> familiesOf(String userId) => List<Family>.unmodifiable(_items);

  /// Tidak memanggil notifyListeners (layar daftar keluarga memantau repository ini).
  @override
  Future<List<Family>> loadFamilies(String userId) async {
    await _reload(userId);
    return familiesOf(userId);
  }

  Future<String> _uniqueCode() async {
    final random = Random.secure();
    for (var i = 0; i < 8; i++) {
      final code = FamilyCode.generate(random, isTaken: (_) => false);
      final snap = await _codes.doc(code).get();
      if (!snap.exists) return code;
    }
    throw const AppException('Gagal membuat kode keluarga. Silakan coba lagi.');
  }

  @override
  Future<Family> create({required String name, required SessionUser user}) async {
    final cleanName = name.trim();
    if (_items.any((f) => f.name.toLowerCase() == cleanName.toLowerCase())) {
      throw const AppException('Kamu sudah punya keluarga dengan nama yang sama.');
    }
    final familyRef = _families.doc();
    final memberRef = familyRef.collection('members').doc();
    await firebaseCall(() async {
      final code = await _uniqueCode();
      final batch = _db.batch();
      batch.set(familyRef, {
        'name': cleanName,
        'code': code,
        'createdBy': user.id,
        'memberUids': [user.id],
        'adminUids': [user.id],
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.set(_codes.doc(code), {'familyId': familyRef.id, 'name': cleanName});
      batch.set(memberRef, {
        'name': user.name,
        'email': user.email.toLowerCase(),
        'role': 'admin',
        'userId': user.id,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
    });
    return _afterChange(user.id, familyRef.id);
  }

  @override
  Future<Family> join({required String code, required SessionUser user}) async {
    final normalized = FamilyCode.normalize(code);
    final email = user.email.toLowerCase();
    late final String familyId;
    await firebaseCall(() async {
      final codeSnap = await _codes.doc(normalized).get();
      if (!codeSnap.exists) {
        throw const AppException('Kode keluarga tidak ditemukan. Periksa kembali kodenya.');
      }
      familyId = codeSnap.data()!['familyId'] as String;
      if (_members.isMember(familyId, user.id)) {
        throw AppException('Kamu sudah menjadi anggota ${codeSnap.data()!['name']}.');
      }
      final familyRef = _families.doc(familyId);
      // Klaim anggota yang sebelumnya ditambahkan admin dengan email yang sama.
      final claim = await familyRef
          .collection('members')
          .where('email', isEqualTo: email)
          .where('userId', isNull: true)
          .limit(1)
          .get();
      final batch = _db.batch();
      batch.update(familyRef, {'memberUids': FieldValue.arrayUnion([user.id])});
      if (claim.docs.isNotEmpty) {
        batch.update(claim.docs.first.reference, {'userId': user.id});
      } else {
        batch.set(familyRef.collection('members').doc(), {
          'name': user.name,
          'email': email,
          'role': 'member',
          'userId': user.id,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    });
    return _afterChange(user.id, familyId);
  }

  Future<Family> _afterChange(String userId, String familyId) async {
    await _reload(userId);
    final family = byId(familyId);
    if (family == null) throw const AppException('Keluarga tidak ditemukan setelah disimpan. Coba muat ulang.');
    notifyListeners();
    return family;
  }
}
