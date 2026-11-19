// Satu-satunya tempat yang merakit repository + controller, dan satu-satunya
// yang boleh mengimpor implementasi di `data/` milik fitur.
import '../../features/auth/auth.dart';
import '../../features/auth/data/firebase_auth_repository.dart';
import '../../features/chatbot/chatbot.dart';
import '../../features/chatbot/data/rule_based_chatbot_repository.dart';
import '../../features/chores/chores.dart';
import '../../features/chores/data/firebase_chore_repository.dart';
import '../../features/family/data/firebase_family_repository.dart';
import '../../features/family/family.dart';
import '../../features/members/data/firebase_member_repository.dart';
import '../../features/members/members.dart';
import '../../shared/session/session.dart';

/// Semua objek yang hidup selama aplikasi berjalan.
class AppDependencies {
  const AppDependencies({
    required this.session,
    required this.auth,
    required this.family,
    required this.members,
    required this.chores,
    required this.chatbot,
  });

  final Session session;
  final AuthController auth;
  final FamilyController family;
  final MembersController members;
  final ChoresController chores;
  final ChatbotController chatbot;
}

class Injection {
  /// Rakit repository Firebase + controller (layar tidak berubah).
  static AppDependencies build() {
    final session = Session();

    final memberRepo = FirebaseMemberRepository(session: session);
    final choreRepo = FirebaseChoreRepository(session: session, members: memberRepo);
    final familyRepo = FirebaseFamilyRepository(members: memberRepo, refreshMembers: memberRepo.loadForFamilies);
    final authRepo = FirebaseAuthRepository();
    final chatbotRepo = RuleBasedChatbotRepository(chores: choreRepo);

    // Anggota saat ini pada Session dihitung dari data members.
    session.bindMemberResolver((userId, familyId) {
      final m = memberRepo.memberOfUser(familyId, userId);
      return m == null ? null : SessionMember(id: m.id, role: m.role);
    });

    return AppDependencies(
      session: session,
      auth: AuthController(
        repository: authRepo,
        session: session,
        onUserNameChanged: memberRepo.syncUserName,
        onSignedIn: familyRepo.refresh,
        onSignedOut: () {
          familyRepo.clear();
          memberRepo.clear();
          choreRepo.clear();
        },
      ),
      family: FamilyController(repository: familyRepo, members: memberRepo, session: session),
      members: MembersController(repository: memberRepo, session: session),
      chores: ChoresController(repository: choreRepo, members: memberRepo, session: session),
      chatbot: ChatbotController(repository: chatbotRepo, session: session),
    );
  }
}
