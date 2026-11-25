# xterm 4.0.0 local changes

Origin: pub.dev xterm 4.0.0 (MIT; original LICENSE retained).

Adds `Terminal.foregroundOverrides(Buffer, row)` as a render-only hook. RenderTerminal passes the returned column/color map to TerminalPainter. The painter applies an override to its temporary CellData only when the cell uses the default foreground, preserving explicitly colored ANSI output and the emulator's text, cursor and selection data. This hook does not change terminal input or parsing behavior.

Salp computes logical-line rules in `lib/core/highlight.dart`, with bounded text/match/cache sizes and regex workers that can time out. Coverage is in `test/highlight_test.dart`.

`CustomTextEdit` now implements `DeltaTextInputClient` and enables the platform delta model. Native Linux input can queue multiple cumulative editing states before a reset arrives; sending each entire state duplicated command prefixes. The delta path emits only inserted text, defers composition until commit (including selection-only commits), and resets the local editing state with the platform. Coverage: `test/terminal_ime_test.dart` and the native keyboard→PTY flow in `integration_test/desktop_flow_test.dart`.

The text input widget is exported through `ui.dart` for the shared RDP/VNC keyboard. Closing its input connection resets composition so lock/focus changes cannot leave stale composition suppressing new keys. Android terminal views enable the sentinel deletion path for soft keyboards that send editing deltas instead of Backspace events.
