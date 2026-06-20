import Foundation

/// Élément de la bibliothèque Stremio (collection `libraryItem`), avec l'état
/// de visionnage (reprise, épisode courant, vu/non-vu). Toutes les durées sont
/// en **millisecondes**. Synchronisé via l'API datastore.
struct LibraryItem: Codable, Sendable, Identifiable {
    let id: String          // _id (ex: "tt0111161")
    let name: String
    let type: String
    let poster: String?
    let posterShape: String?
    var removed: Bool       // soft-delete / sorti de la bibliothèque
    var temp: Bool          // auto-ajouté par la lecture, non explicitement sauvegardé
    let ctime: String?      // _ctime (RFC3339)
    var mtime: String       // _mtime (RFC3339) — à bumper à chaque écriture
    var state: LibraryItemState

    enum CodingKeys: String, CodingKey {
        case id = "_id", name, type, poster, posterShape, removed, temp
        case ctime = "_ctime", mtime = "_mtime", state
    }

    // MARK: Dérivés

    /// Présent dans la bibliothèque « sauvegardée » (favoris).
    var isInLibrary: Bool { !removed && !temp }

    /// Éligible à « Continuer à regarder ».
    var isInContinueWatching: Bool {
        type != "other" && (!removed || temp) && state.timeOffset > 0
    }

    /// Progression 0…1 dans la vidéo courante.
    var progress: Double {
        guard state.timeOffset > 0, state.duration > 0 else { return 0 }
        return min(1, Double(state.timeOffset) / Double(state.duration))
    }

    var isWatched: Bool { state.flaggedWatched > 0 }
    var mtimeDate: Date { DateParsing.date(from: mtime) ?? .distantPast }

    func asPreview() -> MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster,
                    posterShape: posterShape, background: nil, description: nil)
    }

    // MARK: Construction

    /// Nouvel item auto-créé par la lecture : `removed=true, temp=true`
    /// (apparaît dans « Continuer à regarder » mais pas dans la bibliothèque
    /// tant qu'il n'est pas explicitement ajouté).
    init(autoCreatedId id: String, type: String, name: String, poster: String?) {
        self.id = id
        self.name = name
        self.type = type
        self.poster = poster
        self.posterShape = nil
        self.removed = true
        self.temp = true
        self.ctime = DateParsing.nowString()
        self.mtime = self.ctime ?? ""
        self.state = LibraryItemState()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? "other"
        poster = try? c.decode(String.self, forKey: .poster)
        posterShape = try? c.decode(String.self, forKey: .posterShape)
        removed = (try? c.decode(Bool.self, forKey: .removed)) ?? false
        temp = (try? c.decode(Bool.self, forKey: .temp)) ?? false
        ctime = try? c.decode(String.self, forKey: .ctime)
        mtime = (try? c.decode(String.self, forKey: .mtime)) ?? ""
        state = (try? c.decode(LibraryItemState.self, forKey: .state)) ?? LibraryItemState()
    }
}

/// État de visionnage. Durées en **millisecondes**. `video_id` est en snake_case
/// sur le réseau (seule exception au camelCase).
struct LibraryItemState: Codable, Sendable {
    var lastWatched: String?
    var timeWatched: UInt64
    var timeOffset: UInt64           // position de reprise (ms)
    var overallTimeWatched: UInt64
    var timesWatched: UInt32
    var flaggedWatched: UInt32       // 0/1
    var duration: UInt64             // durée totale (ms)
    var videoId: String?             // épisode courant (ex: "tt123:1:5")
    var watched: String?
    var noNotif: Bool?

    enum CodingKeys: String, CodingKey {
        case lastWatched, timeWatched, timeOffset, overallTimeWatched
        case timesWatched, flaggedWatched, duration
        case videoId = "video_id", watched, noNotif
    }

    init(lastWatched: String? = nil, timeWatched: UInt64 = 0, timeOffset: UInt64 = 0,
         overallTimeWatched: UInt64 = 0, timesWatched: UInt32 = 0, flaggedWatched: UInt32 = 0,
         duration: UInt64 = 0, videoId: String? = nil, watched: String? = nil, noNotif: Bool? = nil) {
        self.lastWatched = lastWatched
        self.timeWatched = timeWatched
        self.timeOffset = timeOffset
        self.overallTimeWatched = overallTimeWatched
        self.timesWatched = timesWatched
        self.flaggedWatched = flaggedWatched
        self.duration = duration
        self.videoId = videoId
        self.watched = watched
        self.noNotif = noNotif
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastWatched = try? c.decode(String.self, forKey: .lastWatched)
        timeWatched = (try? c.decode(UInt64.self, forKey: .timeWatched)) ?? 0
        timeOffset = (try? c.decode(UInt64.self, forKey: .timeOffset)) ?? 0
        overallTimeWatched = (try? c.decode(UInt64.self, forKey: .overallTimeWatched)) ?? 0
        timesWatched = (try? c.decode(UInt32.self, forKey: .timesWatched)) ?? 0
        flaggedWatched = (try? c.decode(UInt32.self, forKey: .flaggedWatched)) ?? 0
        duration = (try? c.decode(UInt64.self, forKey: .duration)) ?? 0
        videoId = try? c.decode(String.self, forKey: .videoId)
        watched = try? c.decode(String.self, forKey: .watched)
        noNotif = try? c.decode(Bool.self, forKey: .noNotif)
    }
}

/// Analyse / formatage RFC3339 tolérant (avec ou sans fractions de seconde).
enum DateParsing {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    static func nowString(_ date: Date = Date()) -> String {
        fractional.string(from: date)
    }
}
