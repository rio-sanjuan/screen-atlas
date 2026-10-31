import Foundation

/// A route value: pushing one opens its page through `trailsDestinations()`.
struct Trail: Identifiable, Hashable {
    let id: String
    let name: String
    let region: String
    let miles: Double
    let climbFeet: Int
    let difficulty: String
    let symbol: String
    let elevation: [Int]
}

struct JournalEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let date: String
    let trail: String
    let text: String
}

struct Review: Identifiable {
    let id: String
    let author: String
    let stars: Int
    let text: String
}

enum Sample {
    static let trails = [
        Trail(
            id: "eagle", name: "Eagle Ridge Loop", region: "Northern Range", miles: 7.4, climbFeet: 1820,
            difficulty: "Moderate", symbol: "mountain.2.fill",
            elevation: [5200, 5450, 5800, 6200, 6650, 7020, 6900, 6500, 6100, 5700, 5350, 5200]
        ),
        Trail(
            id: "cedar", name: "Cedar Falls", region: "Mill Valley", miles: 3.1, climbFeet: 540,
            difficulty: "Easy", symbol: "drop.fill",
            elevation: [3100, 3180, 3260, 3400, 3520, 3640, 3500, 3300, 3100]
        ),
        Trail(
            id: "quartz", name: "Quartz Basin", region: "High Lakes", miles: 11.8, climbFeet: 3260,
            difficulty: "Hard", symbol: "snowflake",
            elevation: [6100, 6600, 7200, 7900, 8500, 9050, 9360, 8800, 8000, 7100, 6500, 6100]
        ),
        Trail(
            id: "hidden", name: "Hidden Lake", region: "High Lakes", miles: 5.6, climbFeet: 980,
            difficulty: "Moderate", symbol: "water.waves",
            elevation: [7100, 7300, 7600, 7850, 8080, 7900, 7600, 7300, 7100]
        ),
    ]

    static let entries = [
        JournalEntry(
            id: "snow", title: "First snow on the ridge", date: "Oct 12", trail: "Eagle Ridge Loop",
            text: "Dusting above seven thousand feet. The last mile back was slick, and the view was worth it."
        ),
        JournalEntry(
            id: "falls", title: "Falls running high", date: "Sep 28", trail: "Cedar Falls",
            text: "Two days of rain made the lower crossing interesting. Brought the wrong shoes."
        ),
        JournalEntry(
            id: "lake", title: "Swam at Hidden Lake", date: "Aug 17", trail: "Hidden Lake",
            text: "Colder than it looked. Had the whole shore to myself until noon."
        ),
    ]

    static let reviews = [
        Review(id: "1", author: "Sam", stars: 5, text: "Best views in the range, especially at sunrise."),
        Review(id: "2", author: "Priya", stars: 4, text: "Well marked. The upper switchbacks are steep."),
        Review(id: "3", author: "Jo", stars: 5, text: "Quiet on weekdays. Bring plenty of water."),
    ]

    static let gear = ["Water, 2 liters", "Rain shell", "Headlamp", "First aid kit", "Map and compass", "Snacks"]
}
