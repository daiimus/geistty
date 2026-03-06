//
//  TerminalToolbar.swift
//  Geistty
//
//  UIKit input accessory view providing one-tap access to common terminal
//  symbols and control keys. Displayed above the software keyboard when the
//  terminal surface is the first responder.
//
//  Architecture: Pure UIKit UIInputView — no SwiftUI hosting overhead.
//  Calls SurfaceView.sendText/sendVirtualKey/setCtrlToggle directly.
//

// MARK: - Archived: SwiftUI TerminalToolbar (removed Dec 2025, commit 97ed47d)
// The original SwiftUI-based TerminalToolbar, CtrlToggleButton, CharacterButton,
// and ToolbarButton views were extracted from TerminalContainerView.swift but
// never re-integrated after the UIKit refactor. Archived per directive #6.
// See git history for the full SwiftUI implementation.

import UIKit

// MARK: - TerminalAccessoryView

/// Input accessory view for the terminal software keyboard.
///
/// Provides one-tap access to:
/// - Control keys: Esc, Tab, Ctrl (toggle), arrow keys
/// - Common symbols hard to type on iOS: | ~ ` \ [ ] { } < > _ # $ @
/// - Dismiss keyboard button
///
/// Designed as a `UIInputView` with `.keyboard` style so it adopts the
/// system keyboard appearance automatically.
final class TerminalAccessoryView: UIInputView {

    // MARK: - Action dispatch

    /// Closure to send a text string to the terminal.
    /// Wired to `SurfaceView.sendText(_:)`.
    var onSendText: ((String) -> Void)?

    /// Closure to send a virtual key (Esc, Tab, arrows) to the terminal.
    /// Wired to `SurfaceView.sendVirtualKey(_:)`.
    var onSendVirtualKey: ((Int) -> Void)?

    /// Closure to toggle the Ctrl modifier for the next keypress.
    /// Wired to `SurfaceView.setCtrlToggle(_:)`.
    var onSetCtrlToggle: ((Bool) -> Void)?

    // MARK: - Virtual key constants (match Ghostty.SurfaceView.VirtualKey)

    // These integer tags map to VirtualKey cases — resolved by SurfaceView.
    static let vkEscape   = 0
    static let vkTab      = 1
    static let vkUp       = 2
    static let vkDown     = 3
    static let vkLeft     = 4
    static let vkRight    = 5

    // MARK: - State

    private var ctrlActive = false
    private var ctrlButton: UIButton?

    // Haptic generators (shared, per #40 pattern)
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Init

    init() {
        // Height: 44pt (standard accessory view height)
        let frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        super.init(frame: frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func setupViews() {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // --- Control keys ---

        stack.addArrangedSubview(makeKeyButton(
            symbol: "escape", label: "Esc", tag: Self.vkEscape, action: #selector(virtualKeyTapped(_:))
        ))
        stack.addArrangedSubview(makeKeyButton(
            symbol: "arrow.right.to.line", label: "Tab", tag: Self.vkTab, action: #selector(virtualKeyTapped(_:))
        ))

        let ctrl = makeCtrlButton()
        ctrlButton = ctrl
        stack.addArrangedSubview(ctrl)

        stack.addArrangedSubview(makeKeyButton(
            symbol: "arrow.up", label: "Up arrow", tag: Self.vkUp, action: #selector(virtualKeyTapped(_:))
        ))
        stack.addArrangedSubview(makeKeyButton(
            symbol: "arrow.down", label: "Down arrow", tag: Self.vkDown, action: #selector(virtualKeyTapped(_:))
        ))
        stack.addArrangedSubview(makeKeyButton(
            symbol: "arrow.left", label: "Left arrow", tag: Self.vkLeft, action: #selector(virtualKeyTapped(_:))
        ))
        stack.addArrangedSubview(makeKeyButton(
            symbol: "arrow.right", label: "Right arrow", tag: Self.vkRight, action: #selector(virtualKeyTapped(_:))
        ))

        // --- Divider ---
        stack.addArrangedSubview(makeDivider())

        // --- Symbol characters (issue #14) ---
        // Characters hard to type on the iOS software keyboard.
        // Ordered by frequency in terminal workflows.
        let symbols: [(char: String, label: String)] = [
            ("|",  "pipe"),
            ("~",  "tilde"),
            ("`",  "backtick"),
            ("\\", "backslash"),
            ("[",  "left bracket"),
            ("]",  "right bracket"),
            ("{",  "left brace"),
            ("}",  "right brace"),
            ("<",  "less than"),
            (">",  "greater than"),
            ("_",  "underscore"),
            ("#",  "hash"),
            ("$",  "dollar"),
            ("@",  "at sign"),
        ]

        for sym in symbols {
            stack.addArrangedSubview(makeCharButton(char: sym.char, accessibilityLabel: sym.label))
        }

        // --- Divider ---
        stack.addArrangedSubview(makeDivider())

        // --- Dismiss keyboard ---
        stack.addArrangedSubview(makeKeyButton(
            symbol: "keyboard.chevron.compact.down", label: "Dismiss keyboard", tag: -1, action: #selector(dismissKeyboard)
        ))
    }

    // MARK: - Button Factories

    private func makeKeyButton(symbol: String, label: String?, tag: Int, action: Selector) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        if let label {
            var container = AttributeContainer()
            container.font = UIFont.systemFont(ofSize: 10)
            config.attributedTitle = AttributedString(label, attributes: container)
        }
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.tag = tag
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = label ?? symbol
        button.accessibilityIdentifier = "ToolbarKey-\(label ?? symbol)"
        return button
    }

    private func makeCharButton(char: String, accessibilityLabel: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        var container = AttributeContainer()
        container.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .medium)
        config.attributedTitle = AttributedString(char, attributes: container)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(charButtonTapped(_:)), for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = "ToolbarChar-\(accessibilityLabel)"
        button.accessibilityHint = "Inserts \(char) character"
        return button
    }

    private func makeCtrlButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "control")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        var container = AttributeContainer()
        container.font = UIFont.systemFont(ofSize: 10)
        config.attributedTitle = AttributedString("Ctrl", attributes: container)
        config.baseForegroundColor = .label

        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(ctrlTapped), for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = "Control key modifier"
        button.accessibilityIdentifier = "ToolbarKey-Ctrl"
        button.accessibilityValue = "Inactive"
        button.accessibilityHint = "Double tap to toggle. When active, the next key press will include Control."
        return button
    }

    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        // Add horizontal margins around divider
        let wrapper = UIView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            divider.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            wrapper.widthAnchor.constraint(equalToConstant: 12),
            wrapper.heightAnchor.constraint(equalToConstant: 44),
        ])
        wrapper.accessibilityElementsHidden = true
        return wrapper
    }

    // MARK: - Actions

    @objc private func virtualKeyTapped(_ sender: UIButton) {
        hapticLight.impactOccurred()
        onSendVirtualKey?(sender.tag)
    }

    @objc private func charButtonTapped(_ sender: UIButton) {
        guard let title = sender.configuration?.attributedTitle else { return }
        hapticLight.impactOccurred()
        onSendText?(String(title.characters))
    }

    @objc private func ctrlTapped() {
        ctrlActive.toggle()
        updateCtrlAppearance()
        onSetCtrlToggle?(ctrlActive)
        (ctrlActive ? hapticMedium : hapticLight).impactOccurred()
    }

    @objc private func dismissKeyboard() {
        hapticLight.impactOccurred()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    // MARK: - Ctrl Visual State

    private func updateCtrlAppearance() {
        guard let button = ctrlButton else { return }

        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: ctrlActive ? "control.fill" : "control"
        )?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        config.baseForegroundColor = ctrlActive ? .white : .label
        config.background.backgroundColor = ctrlActive ? .systemOrange : .clear
        config.background.cornerRadius = 8
        button.configuration = config

        button.accessibilityValue = ctrlActive ? "Active" : "Inactive"
        if ctrlActive {
            button.accessibilityTraits.insert(.selected)
        } else {
            button.accessibilityTraits.remove(.selected)
        }
    }

    /// Reset Ctrl toggle state (called when the surface clears it after use)
    func resetCtrlState() {
        guard ctrlActive else { return }
        ctrlActive = false
        updateCtrlAppearance()
    }
}
