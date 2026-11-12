package app.aether.core.profile

import kotlinx.serialization.Serializable

enum class TasteVerdict { LIKE, DISLIKE }

@Serializable
data class TasteVote(
    val id: String,
    val type: String,
    val name: String,
    val poster: String? = null,
    val year: String? = null,
    val genres: List<String> = emptyList(),
    val verdict: TasteVerdict,
    val votedAt: Long = System.currentTimeMillis(),
)

/** The genres a profile can like, with the name the Cinemeta catalogs use. */
enum class ProfileGenre(val title: String, val cinemeta: String, val emoji: String) {
    ACTION("Azione", "Action", "💥"), ADVENTURE("Avventura", "Adventure", "🧭"), ANIMATION("Animazione", "Animation", "🎨"),
    COMEDY("Commedia", "Comedy", "😂"), CRIME("Crime", "Crime", "🕵️"), DOCUMENTARY("Documentari", "Documentary", "🎥"),
    DRAMA("Drammatici", "Drama", "🎭"), FAMILY("Famiglia", "Family", "👨‍👩‍👧"), FANTASY("Fantasy", "Fantasy", "🧙"),
    HISTORY("Storici", "History", "🏛️"), HORROR("Horror", "Horror", "👻"), MUSIC("Musicali", "Music", "🎵"),
    MYSTERY("Mistero", "Mystery", "🔎"), ROMANCE("Romantici", "Romance", "💘"), SCIFI("Fantascienza", "Sci-Fi", "🚀"),
    THRILLER("Thriller", "Thriller", "😰"), WAR("Guerra", "War", "🪖"), WESTERN("Western", "Western", "🤠");

    companion object {
        fun fromCinemeta(name: String): ProfileGenre? = entries.firstOrNull { it.cinemeta.equals(name, true) || it.title.equals(name, true) }
    }
}

data class ProfileAvatar(val id: String, val emoji: String, val from: Long, val to: Long)

object ProfileAvatars {
    val all = listOf(
        ProfileAvatar("popcorn", "🍿", 0xFFFF9F1C, 0xFFE4572E), ProfileAvatar("clapper", "🎬", 0xFF4A4E69, 0xFF22223B),
        ProfileAvatar("reel", "🎞️", 0xFF00A6A6, 0xFF0B3954), ProfileAvatar("alien", "👽", 0xFF7BD389, 0xFF2D6A4F),
        ProfileAvatar("robot", "🤖", 0xFF5BC0EB, 0xFF3A506B), ProfileAvatar("ghost", "👻", 0xFFCDB4DB, 0xFF6D597A),
        ProfileAvatar("vampire", "🧛", 0xFFB5179E, 0xFF3C096C), ProfileAvatar("hero", "🦸", 0xFFF72585, 0xFF7209B7),
        ProfileAvatar("detective", "🕵️", 0xFF6C757D, 0xFF212529), ProfileAvatar("cowboy", "🤠", 0xFFD4A373, 0xFF7F5539),
        ProfileAvatar("ninja", "🥷", 0xFF495057, 0xFF0B090A), ProfileAvatar("dragon", "🐉", 0xFFEF476F, 0xFF7B2CBF),
        ProfileAvatar("dino", "🦖", 0xFF80B918, 0xFF2B9348), ProfileAvatar("astronaut", "🧑‍🚀", 0xFF4361EE, 0xFF10002B),
        ProfileAvatar("wizard", "🧙", 0xFF7400B8, 0xFF240046), ProfileAvatar("masks", "🎭", 0xFFFFD166, 0xFFEF476F),
        ProfileAvatar("rocket", "🚀", 0xFF48CAE4, 0xFF023E8A), ProfileAvatar("ticket", "🎟️", 0xFFF4A261, 0xFF264653),
    )

    fun avatar(id: String): ProfileAvatar = all.firstOrNull { it.id == id } ?: all[0]
}

/** Who watches: a name, an avatar, the genres they like and the votes of the taste game (the same model as the iPhone). */
@Serializable
data class ProfileSettings(
    val name: String = "",
    val avatar: String = "popcorn",
    val genres: List<String> = emptyList(),
    val votes: List<TasteVote> = emptyList(),
    val skipped: List<String> = emptyList(),
) {
    val displayName: String? get() = name.trim().takeIf { it.isNotEmpty() }
    val likes: List<TasteVote> get() = votes.filter { it.verdict == TasteVerdict.LIKE }.sortedByDescending { it.votedAt }
    val dislikes: List<TasteVote> get() = votes.filter { it.verdict == TasteVerdict.DISLIKE }.sortedByDescending { it.votedAt }
    val chosenGenres: List<ProfileGenre> get() = genres.mapNotNull { g -> ProfileGenre.entries.firstOrNull { it.name.equals(g, true) } }

    fun vote(vote: TasteVote) = copy(votes = votes.filter { it.id != vote.id } + vote, skipped = skipped - vote.id)
    fun skip(id: String) = copy(skipped = (skipped - id + id).takeLast(400))
    fun toggleGenre(genre: ProfileGenre) = copy(genres = if (genre.name in genres) genres - genre.name else genres + genre.name)

    /**
     * The genres the viewer likes most: those chosen count three, each liked title one per genre, each disliked one minus one. The
     * taste game and the recommendations start from here.
     */
    fun topGenres(limit: Int = 4): List<ProfileGenre> {
        val score = HashMap<ProfileGenre, Int>()
        chosenGenres.forEach { score[it] = (score[it] ?: 0) + 3 }
        for (v in votes) for (g in v.genres.mapNotNull { ProfileGenre.fromCinemeta(it) }) score[g] = (score[g] ?: 0) + if (v.verdict == TasteVerdict.LIKE) 1 else -1
        return score.entries.filter { it.value > 0 }.sortedByDescending { it.value }.take(limit).map { it.key }
    }
}
