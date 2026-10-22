# Repository Agent Instructions

These instructions apply to **all agents working on WrongBook**. Follow task-specific instructions as well; if they conflict on safety or authorization, use the stricter requirement.

## Physical Device Proceed Protocol

**Do not ask the owner to connect an iPhone or iPad until physical hardware is genuinely required for the next action.**

1. **Do work without the device first.** Finish source inspection, implementation, builds, signing preparation, unit/integration tests, and all feasible Simulator QA before requesting hardware. Do not request a device for code review, compilation, log analysis, Simulator use, or work that can run without it.
2. **Make the request only at the handoff point.** Explain which physical device is needed, exactly what operation will run (such as installing a signed QA build or collecting device logs), and that the owner should connect it, unlock it, and approve Trust/Allow prompts if shown.
3. **Require an explicit local terminal confirmation:** display **“Connect and unlock your iPad, then type y + Enter to proceed (anything else cancels).”** Wait for the owner to actually type `y` and press Enter. Default to cancel; never automatically answer the prompt, synthesize confirmation, or treat the mere presence of a cable as authorization.
4. **Verify the correct device after confirmation.** Use `xcrun devicectl list devices` (or an equivalent authoritative tool) to identify the intended device and its connection/availability before install, launch, capture, or other device-side commands. If there is ambiguity or a Trust/unlock blocker, stop and provide one specific action for the owner rather than guessing. Do not silently switch to another device.
5. **Proceed only with the described, authorized operation.** Preserve app and device data. Installing a QA app is not authorization to uninstall/reset it, redeem Apple offers, initiate a purchase, Restore Purchases, call `syncPurchases()`, transfer ownership, modify billing/credit records, or deploy anything. Those require separate explicit approval.
6. **Avoid idle hardware waits.** Complete all independent preparation before prompting. If the agent's tooling cannot safely pause for a human's terminal input, provide the precise local command/procedure and **STOP**, rather than polling, pretending the device is connected, or keeping a remote job running indefinitely.

A practical interactive shell gate, to run **only after the build and installation command are ready**, is:

```bash
printf 'Connect and unlock your iPad, then type y + Enter to proceed (anything else cancels): '
IFS= read -r proceed
if [ "$proceed" != y ]; then
  echo 'Device operation cancelled.'
  exit 0
fi
xcrun devicectl list devices
# Verify the intended device identity/availability before any install or launch.
```

**Scope of `y`:** permission for the explicitly stated physical-device operation **only**, never blanket permission for purchases or other side effects.

When an agent works from a feature branch that does not yet contain this file, read the canonical `main:AGENTS.md` from GitHub before physical-device work. Keep task-specific security and test gates intact.
