import Foundation

/// A turn the room list started, waiting for the room screen to pick it up.
///
/// Starting a conversation from the list sends its first words and begins the
/// turn on the server in one call. The room screen that opens next must follow
/// that turn -- not send the words again, which would ask Hermes twice. The list
/// and the room have separate stores, so the turn is passed across here, once.
@MainActor final class HermesHandoff {
    static let shared = HermesHandoff()

    struct Opening: Equatable {
        let text: String
        /// The pictures attached to the opening words, as sent: the room shows them
        /// on the first row straight away, as it does for a message sent from inside.
        var images: [String] = []
        let turnID: String
    }

    private var held: [String: Opening] = [:]

    func hold(roomID: String, text: String, images: [String] = [], turnID: String) {
        held[roomID] = Opening(text: text, images: images, turnID: turnID)
    }

    /// The opening for a room, handed over at most once: a second screen for the
    /// same room must not follow the same turn again.
    func take(roomID: String) -> Opening? {
        held.removeValue(forKey: roomID)
    }
}
