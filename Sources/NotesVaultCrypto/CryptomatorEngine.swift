import Foundation
import CryptomatorCryptoLib
import NotesVaultCore

/// `VaultCryptoEngine` backed by Cryptomator's audited library.
///
/// Decision 04: reuse an audited, open-source vault format — including encrypted filenames
/// — rather than roll our own. Everything cryptographic in this app happens inside this
/// file, and every line of it delegates. There is no bespoke primitive here to review.
///
/// A secondary benefit that turns principle 05 from a claim into a fact: because this is a
/// real Cryptomator vault, a counsellor can open it in Cryptomator's own app on any
/// platform, with no cooperation from us, forever. That is the escape hatch.
public final class CryptomatorEngine: VaultCryptoEngine {
    private let cryptor: Cryptor

    public init(cryptor: Cryptor) {
        self.cryptor = cryptor
    }

    public func hashedDirectoryID(_ directoryID: Data) throws -> String {
        do {
            return try cryptor.encryptDirId(directoryID)
        } catch {
            throw VaultError.cryptoFailure("could not hash a directory id: \(error.localizedDescription)")
        }
    }

    public func encryptFilename(_ cleartext: String, directoryID: Data) throws -> String {
        do {
            return try cryptor.encryptFileName(cleartext, dirId: directoryID)
        } catch {
            throw VaultError.cryptoFailure("could not encrypt the name \"\(cleartext)\": \(error.localizedDescription)")
        }
    }

    public func decryptFilename(_ ciphertext: String, directoryID: Data) throws -> String {
        do {
            return try cryptor.decryptFileName(ciphertext, dirId: directoryID)
        } catch {
            throw VaultError.cryptoFailure("could not decrypt a filename: \(error.localizedDescription)")
        }
    }

    public func encryptContent(_ plaintext: Data) throws -> Data {
        do {
            return try PlaintextScratch.withScratchDirectory { directory in
                let cleartextURL = directory.appendingPathComponent("in")
                let ciphertextURL = directory.appendingPathComponent("out")
                try plaintext.write(to: cleartextURL, options: PlaintextScratch.writeOptions)
                try cryptor.encryptContent(from: cleartextURL, to: ciphertextURL)
                return try Data(contentsOf: ciphertextURL)
            }
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.cryptoFailure("could not encrypt a note: \(error.localizedDescription)")
        }
    }

    public func decryptContent(_ ciphertext: Data) throws -> Data {
        do {
            return try PlaintextScratch.withScratchDirectory { directory in
                let ciphertextURL = directory.appendingPathComponent("in")
                let cleartextURL = directory.appendingPathComponent("out")
                try ciphertext.write(to: ciphertextURL, options: PlaintextScratch.writeOptions)
                try cryptor.decryptContent(from: ciphertextURL, to: cleartextURL)
                return try Data(contentsOf: cleartextURL)
            }
        } catch let error as VaultError {
            throw error
        } catch {
            // A failure here is usually an authentication failure, which means the file has
            // been altered since it was written. Say so plainly — this is one of the very
            // few messages in the app that should worry the person reading it.
            throw VaultError.cryptoFailure("this note could not be decrypted, which means it has been changed or damaged since it was written (\(error.localizedDescription))")
        }
    }
}
