## 1.0.0

- Initial release
- Standalone Warlock-only Soulstone reminder
- Proof-only clearing: the reminder hides only when the addon can prove the active Soulstone was cast by the local player
- Solo support: Soulstone on yourself clears the banner
- Group support: Soulstone on a current party or raid member clears the banner only when `sourceUnit` resolves to the local player
- Restriction-aware aura scanning using modern `C_UnitAuras` APIs
- Compact upper-center reminder banner with no setup, chat spam, or external dependencies
