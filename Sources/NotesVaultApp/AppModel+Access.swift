import Foundation
import NotesVaultCore
import NotesVaultCrypto

/// Getting in, staying in, and the things that decide who can: unlocking, the checks, the
/// passphrase and the recovery key.
extension AppModel {
    /// Whether the splash is covering the app. See `PresenceTracker.isShielded`.
    public var isShielded: Bool { presence.isShielded }

    /// The name this device writes into every note it creates.
    public var deviceDisplayName: String { DeviceIdentity.current }

    public var biometricsAvailable: Bool { KeychainStore.biometricsAvailable }

    /// Whether this device can be asked to confirm the counsellor is present at all, and
    /// what it would ask with. Both are read fresh: Face ID can be turned off in the
    /// device's own settings between one launch and the next.
    public var deviceCheckAvailable: Bool { DeviceCheck.isAvailable }
    public var deviceCheckMethod: DeviceCheck.Method { DeviceCheck.method }

    // MARK: - Creating and unlocking

    public func createVault(passphrase: String) async {
        guard let files else { return }
        await run("Creating the vault…") {
            try VaultBootstrap.createVault(in: files, passphrase: passphrase)
        } then: { [weak self] created in
            guard let self else { return }
            self.adopt(session: created.session, files: files)
            self.pendingRecoveryKey = created.recoveryKey
            self.phase = .revealRecoveryKey
        }
    }

    /// The counsellor has confirmed they have written the recovery key down. It is dropped
    /// from memory here and there is no way back to it — which is the point.
    public func acknowledgeRecoveryKey() {
        pendingRecoveryKey = nil
        phase = .unlocked
        Task { await refreshIndex(force: true) }
    }

    public func unlock(passphrase: String, rememberWithBiometrics: Bool = false) async {
        guard let files else { return }
        await run("Unlocking…") {
            try VaultBootstrap.open(files, passphrase: passphrase)
        } then: { [weak self] session in
            guard let self else { return }
            self.adopt(session: session, files: files)
            if rememberWithBiometrics {
                KeychainStore.storePassphrase(passphrase, vaultID: session.configuration.jti)
                // After `adopt`, which has already asked and been told no.
                self.refreshBiometricsEnrolled()
            }
            // Typing the passphrase *is* a check, and the strongest one this app has, so it
            // stands for the next minute like any other — opening a note straight after
            // unlocking does not ask twice.
            self.presence.recordCheckPassed()
            self.lockReason = .manual
            self.phase = .unlocked
            Task { await self.refreshIndex(force: false) }
        }
    }

    /// Unlocks using the passphrase held behind Face ID / Touch ID.
    ///
    /// Needs the vault's identifier before it can find the keychain item, and that lives in
    /// the vault config — which is readable without the key, because it is signed rather
    /// than encrypted.
    public func unlockWithBiometrics() async {
        guard let files else { return }
        guard let vaultIdentifier = vaultID ?? Self.readVaultID(from: files) else {
            errorMessage = "The vault folder couldn't be read — check it's still where you left it."
            return
        }

        // Off the main thread on purpose. `SecItemCopyMatching` on an item behind
        // `.userPresence` does not return until the counsellor has answered the prompt, so
        // called here — on the main actor — it holds the main thread for as long as somebody
        // takes to look at their phone. Everything the app draws is frozen for that whole
        // time, the scene's own comings and goings queue up behind it, and iOS is entitled
        // to kill an app that stops answering for long enough.
        let result = await Task.detached(priority: .userInitiated) {
            KeychainStore.passphrase(vaultID: vaultIdentifier, reason: "Unlock your clinical notes")
        }.value

        switch result {
        case .value(let passphrase):
            await unlock(passphrase: passphrase)
        case .cancelled:
            // Declining is a normal choice — the passphrase field is still right there.
            break
        case .failed:
            // Somebody's face or passcode did not match. The passphrase is the only way in
            // from here: `lockReason` stops the screen offering the check again.
            lockReason = .checkFailed
        case .unavailable:
            errorMessage = "Face ID unlock isn't set up any more on this device — use your passphrase, then turn it back on from the unlock screen."
            KeychainStore.remove(.passphrase, vaultID: vaultIdentifier)
            refreshBiometricsEnrolled()
        }
    }

    // MARK: - Checks
    //
    // Where the app asks "is this still you?", and nowhere else:
    //
    //   * coming back to the app, unless the counsellor has set a grace period and is
    //     inside it (`becameActive`);
    //   * opening a note, which is the clinical content itself;
    //   * changing something that decides who gets in — the passphrase, the recovery key,
    //     this setting, the folder, an export, a destruction.
    //
    // Everywhere else the door has already been answered. A check that fails is never
    // survivable: it drops the key and puts the passphrase in the way, because a check
    // that can be shrugged off is decoration.

    /// Confirms the counsellor is present, for one action inside an already-unlocked app.
    ///
    /// Returns whether the action may go ahead. A refusal is complete — the caller must do
    /// nothing at all — and after a *failed* check there is no longer an unlocked app to
    /// return to.
    public func confirmIdentity(reason: String) async -> Bool {
        guard phase == .unlocked else { return false }
        if presence.checkStands() { return true }

        // A device with no biometry and no passcode cannot be asked, and an unlocked vault
        // is already as far as this app's own evidence goes: the passphrase was typed to
        // get here. Refusing everything would mean a passphrase before every note, which
        // ends with the passphrase taped to the back of the phone. Settings says plainly
        // that this device has no check.
        guard DeviceCheck.isAvailable else { return true }

        presence.beginCheck()
        let outcome = await DeviceCheck.confirm(reason: reason)
        presence.endCheck()

        switch outcome {
        case .passed:
            presence.recordCheckPassed()
            return true
        case .cancelled:
            // Changed their mind, or handed the phone back. Costs them this action and
            // nothing else — nothing was shown, so nothing needs taking away.
            return false
        case .failed:
            lock(reason: .checkFailed)
            return false
        case .unavailable:
            // Biometry and passcode both disappeared between `isAvailable` and here.
            lock(reason: .checkUnavailable)
            return false
        }
    }

    /// The app is leaving the foreground. See `PresenceTracker.leaveForeground`.
    public func enterBackground(reallyAway: Bool, at date: Date = Date()) {
        presence.leaveForeground(reallyAway: reallyAway, at: date)
    }

    /// The app is back on screen. Resolves whatever the time away costs before the shield
    /// comes down, so nothing is visible until it has been paid.
    public func becameActive(at date: Date = Date()) async {
        // Predictions and retention depend on the date, and the app may have been away
        // across midnight.
        recomputeDerived()

        switch presence.becameActive(at: date, isUnlocked: phase == .unlocked, policy: lockPolicy) {
        case .nothing:
            break
        case .offerBiometricUnlock:
            await unlockIfBiometricsOffered()
        case .confirmPresence:
            let outcome = await DeviceCheck.confirm(reason: "Confirm it's you to open your notes")
            presence.endCheck()
            switch outcome {
            case .passed:
                presence.recordCheckPassed()
            case .cancelled:
                lock(reason: .away)
            case .failed:
                lock(reason: .checkFailed)
            case .unavailable:
                lock(reason: .checkUnavailable)
            }
            presence.lowerShield()
        case .lock:
            lock(reason: .away)
            presence.lowerShield()
            await unlockIfBiometricsOffered()
        }
    }

    /// Starts the biometric unlock when the lock screen is entitled to offer it, so a
    /// reopen is one glance rather than a glance and a tap.
    public func unlockIfBiometricsOffered() async {
        guard phase == .locked, lockReason.allowsBiometricUnlock, biometricsEnrolled else { return }
        presence.beginCheck()
        await unlockWithBiometrics()
        presence.endCheck()
    }

    /// Changes how long the app may be away before it asks again — itself a check, since a
    /// lock setting anyone holding the phone could loosen is not a lock setting.
    @discardableResult
    public func setReopenGrace(_ seconds: TimeInterval) async -> Bool {
        guard lockPolicy.reopenGrace != seconds else { return true }
        guard await confirmIdentity(reason: "Confirm it's you before changing when the app asks again") else {
            return false
        }
        lockPolicy.reopenGrace = seconds
        Self.saveSetting(lockPolicy, key: Self.lockPolicyKey)
        return true
    }

    // MARK: - Passphrase

    public func changePassphrase(current: String, new: String) async -> Bool {
        guard let files else { return false }
        // Not session-bound: once the file is rewritten the old passphrase is gone, and the
        // Face ID copy below has to follow it whether or not the app locked meanwhile.
        let succeeded = await run("Changing the passphrase…", sessionBound: false) {
            try VaultBootstrap.changePassphrase(in: files, current: current, new: new)
        } then: { _ in }
        if succeeded, let vaultID, KeychainStore.hasStoredPassphrase(vaultID: vaultID) {
            KeychainStore.storePassphrase(new, vaultID: vaultID)
        }
        return succeeded
    }

    public func resetPassphrase(recoveryKey: RecoveryKey, newPassphrase: String) async -> Bool {
        guard let files else { return false }
        let succeeded = await run("Restoring access…", sessionBound: false) {
            try VaultBootstrap.resetPassphrase(in: files, recoveryKey: recoveryKey, newPassphrase: newPassphrase)
        } then: { _ in }

        // The passphrase behind Face ID is the one just replaced. Left there, the next
        // biometric unlock would try it and report "wrong passphrase" to somebody who has
        // just done everything right. Removed rather than updated: a recovery is exactly
        // when to make the counsellor choose to turn Face ID on again, from the unlock
        // screen, with the new passphrase.
        if succeeded, let forgotten = vaultID ?? Self.readVaultID(from: files) {
            KeychainStore.remove(.passphrase, vaultID: forgotten)
            refreshBiometricsEnrolled()
        }
        return succeeded
    }

    // MARK: - Recovery key

    /// Makes a new recovery key and shows it. Writes nothing: the old key keeps working
    /// until the new one has been typed back and `confirmRecoveryKey` has run.
    ///
    /// It used to be the other way round — the new key written the moment it was made —
    /// which meant a lock, a crash or a closed sheet before it was copied down left a vault
    /// whose only recovery key had been on screen for a moment and nowhere else.
    public func regenerateRecoveryKey(passphrase: String) async {
        guard let files else { return }
        await run("Issuing a new recovery key…") {
            try VaultBootstrap.prepareRecoveryKey(in: files, passphrase: passphrase)
        } then: { [weak self] prepared in
            self?.pendingReissue = prepared
            self?.pendingRecoveryKey = prepared.key
        }
    }

    /// The new key has been typed back: write it, which is the moment the old one stops
    /// working. Returns whether it was written.
    public func confirmRecoveryKey() async -> Bool {
        guard let files, let prepared = pendingReissue else { return false }
        let installed = await run("Issuing a new recovery key…") {
            try VaultBootstrap.installRecoveryKey(prepared, in: files)
        } then: { [weak self] _ in
            self?.pendingReissue = nil
            self?.pendingRecoveryKey = nil
        }
        return installed
    }

    /// Puts a recovery key away. For a reissued key that was never confirmed this abandons
    /// it, and the old key is still the one that works.
    public func dismissRecoveryKey() {
        pendingReissue = nil
        pendingRecoveryKey = nil
    }
}
