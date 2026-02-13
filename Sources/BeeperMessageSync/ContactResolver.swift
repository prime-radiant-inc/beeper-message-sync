import Contacts
import Foundation

struct ContactResolver: Sendable {
    private let phoneToName: [String: String]

    init(phoneToName: [String: String] = [:]) {
        self.phoneToName = phoneToName
    }

    /// Build a resolver by enumerating all macOS Contacts
    static func load() -> ContactResolver {
        let store = CNContactStore()
        var status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var granted = false
            store.requestAccess(for: .contacts) { ok, _ in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            status = granted ? .authorized : .denied
        }

        guard status == .authorized else {
            print("  Contacts access not available (status: \(status.rawValue)) — phone numbers won't be resolved")
            return ContactResolver()
        }

        var cache: [String: String] = [:]
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard !name.isEmpty else { return }

                for phone in contact.phoneNumbers {
                    let normalized = normalizePhoneNumber(phone.value.stringValue)
                    if !normalized.isEmpty {
                        cache[normalized] = name
                    }
                }
            }
        } catch {
            print("  Failed to enumerate contacts: \(error) — phone numbers won't be resolved")
            return ContactResolver()
        }

        print("  Loaded \(cache.count) phone→name mappings from Contacts")
        return ContactResolver(phoneToName: cache)
    }

    /// Look up a phone number, with fallback to last-10-digit matching
    func resolve(_ phoneNumber: String) -> String? {
        let normalized = Self.normalizePhoneNumber(phoneNumber)
        if let name = phoneToName[normalized] {
            return name
        }

        // Fallback: match on last 10 digits (handles missing country code)
        let digits = normalized.filter(\.isNumber)
        let last10 = digits.count >= 10 ? String(digits.suffix(10)) : digits

        for (key, name) in phoneToName {
            let keyDigits = key.filter(\.isNumber)
            let keyLast10 = keyDigits.count >= 10 ? String(keyDigits.suffix(10)) : keyDigits
            if !last10.isEmpty && last10 == keyLast10 {
                return name
            }
        }

        return nil
    }

    /// Heuristic: does this string look like a phone number?
    /// Must contain 7+ digits and only phone-number characters
    static func looksLikePhoneNumber(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }

        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        let scalars = string.unicodeScalars
        guard scalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let digitCount = string.filter(\.isNumber).count
        return digitCount >= 7
    }

    /// Strip formatting, keep leading + and digits only
    static func normalizePhoneNumber(_ raw: String) -> String {
        var result = ""
        for (i, char) in raw.enumerated() {
            if char == "+" && i == 0 {
                result.append(char)
            } else if char.isNumber {
                result.append(char)
            }
        }
        return result
    }
}
