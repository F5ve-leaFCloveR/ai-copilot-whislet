import Foundation
import CopilotCore

enum ConversationProfileKind: String, Codable, Equatable, Sendable {
    case interview, work, recruiterInterview

    var title: String {
        switch self {
        case .interview: "Собеседование"
        case .work: "Рабочий созвон"
        case .recruiterInterview: "Интервью по опыту · English"
        }
    }
    var conversationMode: ConversationMode {
        switch self {
        case .interview: .interview
        case .work: .work
        case .recruiterInterview: .recruiterInterview
        }
    }
}

struct ConversationProfile: Identifiable, Codable, Equatable, Sendable {
    static let legacyInterviewID = UUID(uuidString: "9C2D57B2-3319-4D36-87BE-3E4F37F85926")!
    var id: UUID
    var name: String
    var kind: ConversationProfileKind
    var context: String
    var vacancy: String
    var knowledgeFile: String?

    init(id: UUID = UUID(), name: String, kind: ConversationProfileKind = .interview, context: String = "", vacancy: String = "", knowledgeFile: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.context = context; self.vacancy = vacancy; self.knowledgeFile = knowledgeFile
    }
}

extension UISettings {
    var activeProfile: ConversationProfile {
        var value = profiles?.first(where: { $0.id == selectedProfileID }) ?? profiles?.first ?? ConversationProfile(id: ConversationProfile.legacyInterviewID, name: profileName)
        value.name = profileName; value.context = profile; value.vacancy = vacancy
        return value
    }

    var availableProfiles: [ConversationProfile] {
        guard let profiles, !profiles.isEmpty else { return [activeProfile] }
        return profiles.map { $0.id == activeProfile.id ? activeProfile : $0 }
    }

    mutating func migrateProfiles() {
        guard let profiles, !profiles.isEmpty else {
            let value = ConversationProfile(id: ConversationProfile.legacyInterviewID, name: profileName, context: profile, vacancy: vacancy)
            self.profiles = [value]; selectedProfileID = value.id
            return
        }
        let value = profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
        selectedProfileID = value.id
        profileName = value.name; profile = value.context; vacancy = value.vacancy
    }

    mutating func syncActiveProfile() {
        if profiles?.isEmpty != false { migrateProfiles(); return }
        let index = profiles?.firstIndex(where: { $0.id == selectedProfileID }) ?? 0
        selectedProfileID = profiles?[index].id
        profiles?[index].name = profileName; profiles?[index].context = profile; profiles?[index].vacancy = vacancy
    }

    @discardableResult
    mutating func selectProfile(_ id: UUID) -> Bool {
        guard availableProfiles.contains(where: { $0.id == id }) else { return false }
        syncActiveProfile()
        guard let value = profiles?.first(where: { $0.id == id }) else { return false }
        selectedProfileID = value.id
        profileName = value.name; profile = value.context; vacancy = value.vacancy
        return true
    }

    @discardableResult
    mutating func addProfile(kind: ConversationProfileKind, duplicateCurrent: Bool = false) -> UUID {
        syncActiveProfile()
        let current = activeProfile
        let name = duplicateCurrent ? current.name + " · копия" : kind.title
        let value = ConversationProfile(name: name, kind: duplicateCurrent ? current.kind : kind, context: duplicateCurrent ? current.context : "", vacancy: duplicateCurrent ? current.vacancy : "", knowledgeFile: duplicateCurrent ? current.knowledgeFile : nil)
        profiles?.append(value)
        _ = selectProfile(value.id)
        return value.id
    }

    @discardableResult
    mutating func deleteActiveProfile() -> Bool {
        guard availableProfiles.count > 1 else { return false }
        syncActiveProfile()
        let id = selectedProfileID
        profiles?.removeAll(where: { $0.id == id })
        guard let replacement = profiles?.first else { return false }
        selectedProfileID = replacement.id
        profileName = replacement.name; profile = replacement.context; vacancy = replacement.vacancy
        return true
    }
}
