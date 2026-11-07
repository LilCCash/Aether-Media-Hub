import Foundation

/// Merging what two devices wrote in a shared file: nothing is lost, the newer wins where both changed the same thing.
/// Only what the viewer produces is merged (diary, collections, votes, followed universes); the other settings stay each device's own.
public enum ContentSync {
    public static func merge(local: ContentSettings, remote: ContentSettings) -> ContentSettings {
        var result = local

        // Diary: by id. The same viewing on both sides keeps the version with the later date of watching, a viewing on one side is added.
        var diary: [String: DiaryEntry] = [:]
        for entry in local.diary.entries { diary[entry.id] = entry }
        for entry in remote.diary.entries {
            if let known = diary[entry.id] { if entry.watchedAt > known.watchedAt || (entry.watchedAt == known.watchedAt && entry.note.count > known.note.count) { diary[entry.id] = entry } }
            else { diary[entry.id] = entry }
        }
        result.diary.entries = diary.values.sorted { $0.watchedAt > $1.watchedAt }

        // Collections: by id; the name of the local one stays, the titles of both are kept.
        var lists = local.collections.collections
        for list in remote.collections.collections {
            if let index = lists.firstIndex(where: { $0.id == list.id }) {
                for item in list.items where !lists[index].items.contains(where: { $0.id == item.id }) { lists[index].items.append(item) }
            } else if let same = lists.firstIndex(where: { $0.name.caseInsensitiveCompare(list.name) == .orderedSame }) {
                for item in list.items where !lists[same].items.contains(where: { $0.id == item.id }) { lists[same].items.append(item) }
            } else {
                lists.append(list)
            }
        }
        result.collections.collections = lists

        // Votes of the taste game: by title, the latest verdict wins.
        var votes: [String: TasteVote] = [:]
        for vote in local.profile.votes { votes[vote.id] = vote }
        for vote in remote.profile.votes { if let known = votes[vote.id], known.votedAt >= vote.votedAt { continue }; votes[vote.id] = vote }
        result.profile.votes = votes.values.sorted { $0.votedAt > $1.votedAt }
        result.profile.skipped = Array(Set(local.profile.skipped + remote.profile.skipped))
        for genre in remote.profile.genres where !result.profile.genres.contains(genre) { result.profile.genres.append(genre) }
        if result.profile.name.isEmpty { result.profile.name = remote.profile.name }

        // Universes: followed ones are joined; an order the viewer arranged on one device only is taken.
        for id in remote.universes.followed where !result.universes.followed.contains(id) { result.universes.followed.append(id) }
        for (id, order) in remote.universes.customOrders where result.universes.customOrders[id] == nil { result.universes.customOrders[id] = order }
        return result
    }
}
