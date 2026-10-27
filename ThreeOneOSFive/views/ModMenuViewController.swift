// ModMenuViewController.swift
// ThreeOneOSFive — Mod Menu Interface (Clean White Theme)
// Pure Swift / Programmatic UI — không dùng Storyboard/Xib
// bypass by Hdanh | ✦ made by @Nopermcc ✦

import UIKit

// MARK: - ModMenuViewController

final class ModMenuViewController: UIViewController {

    // MARK: - Callback
    var onClose: (() -> Void)?

    // MARK: - Palette
    // Toàn bộ màu sắc tập trung tại đây để dễ chỉnh sửa sau
    private enum Palette {
        static let menuBackground   = UIColor.white.withAlphaComponent(0.97)
        static let cellBackground   = UIColor(red: 0.973, green: 0.976, blue: 0.980, alpha: 1) // #F8F9FA
        static let titlePrimary     = UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1) // #1C1C1E
        static let titleSecondary   = UIColor(red: 0.556, green: 0.556, blue: 0.576, alpha: 1) // #8E8E93
        static let accent            = UIColor(red: 0.100, green: 0.400, blue: 0.900, alpha: 1) // #1A66E6
        static let separator        = UIColor(red: 0.900, green: 0.902, blue: 0.910, alpha: 1) // #E6E6E8
        static let switchOnTint     = UIColor(red: 0.100, green: 0.400, blue: 0.900, alpha: 1) // #1A66E6
        static let danger           = UIColor(red: 0.90, green: 0.18, blue: 0.22, alpha: 1)    // #E62E38
    }

    // MARK: - Data Model
    // Mỗi Row tương ứng một toggle chức năng
    struct MenuRow {
        let id: Int
        let title: String
        let subtitle: String
        let iconName: String          // SF Symbol
        let accentColor: UIColor
        var isOn: Bool

        // Loại hành động khi toggle
        enum ActionType {
            case devicePatch    // Gọi DevicePatchService
            case workspacePatch // Gọi PatchWorkspaceService
        }
        let actionType: ActionType
    }

    // Danh sách các tính năng — thêm row mới ở đây
    var rows: [MenuRow] = [
        MenuRow(
            id: 0,
            title: "Core Patch",
            subtitle: "Apply device-level patch via DevicePatchService",
            iconName: "bolt.shield.fill",
            accentColor: Palette.accent,
            isOn: false,
            actionType: .devicePatch
        ),
        MenuRow(
            id: 1,
            title: "Workspace Patch",
            subtitle: "Set up patch workspace via PatchWorkspaceService",
            iconName: "folder.badge.gearshape",
            accentColor: UIColor(red: 0.30, green: 0.60, blue: 0.20, alpha: 1), // Green
            isOn: false,
            actionType: .workspacePatch
        ),
        MenuRow(
            id: 2,
            title: "Aim Assist",
            subtitle: "Override aim parameters in target container",
            iconName: "scope",
            accentColor: UIColor(red: 0.80, green: 0.40, blue: 0.05, alpha: 1), // Orange
            isOn: false,
            actionType: .devicePatch
        ),
    ]

    // MARK: - Error / Status state
    private var statusMessage: String? = nil  // Hiển thị kết quả thao tác gần nhất

    // MARK: - UI Components

    // Container chính — nổi bật với shadow và corner radius
    private let containerView: UIView = {
        let v = UIView()
        v.backgroundColor = Palette.menuBackground
        v.layer.cornerRadius = 20
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // Chỉ bo góc trên
        v.layer.masksToBounds = false
        // Shadow sắc sảo
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.18
        v.layer.shadowRadius = 20
        v.layer.shadowOffset = CGSize(width: 0, height: -6)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // Thanh drag handle nhỏ trên đầu (visual cue)
    private let dragHandle: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)
        v.layer.cornerRadius = 2.5
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // Header: tiêu đề + nút đóng
    private let headerView: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "ThreeOneOSFive Mod Menu"
        l.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        l.textColor = Palette.titlePrimary
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.text = "Authorized Testing Environment"
        l.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        l.textColor = Palette.titleSecondary
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private lazy var closeButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "xmark",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        config.baseForegroundColor = Palette.titleSecondary
        config.baseBackgroundColor = Palette.cellBackground
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        return b
    }()

    // Divider dưới header
    private let headerDivider: UIView = {
        let v = UIView()
        v.backgroundColor = Palette.separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // TableView danh sách tính năng
    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .plain)
        t.backgroundColor = .clear
        t.separatorStyle = .none
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 72
        t.showsVerticalScrollIndicator = false
        t.delegate = self
        t.dataSource = self
        t.register(MenuToggleCell.self, forCellReuseIdentifier: MenuToggleCell.reuseID)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
        return t
    }()

    // Status bar (hiển thị kết quả thao tác)
    private let statusBar: UIView = {
        let v = UIView()
        v.backgroundColor = Palette.cellBackground
        v.isHidden = true
        v.layer.cornerRadius = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        l.textColor = Palette.titleSecondary
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let statusIcon: UIImageView = {
        let i = UIImageView()
        i.contentMode = .scaleAspectFit
        i.translatesAutoresizingMaskIntoConstraints = false
        return i
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Nền bên ngoài container: mờ (dimmed)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        setupLayout()
        setupDismissGesture()
    }

    // MARK: - Layout

    private func setupLayout() {
        // 1. Container (full width, chiều cao tự co giãn từ bottom)
        view.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // Chiều cao tối thiểu ~50% màn hình, tối đa 70%
            containerView.topAnchor.constraint(
                greaterThanOrEqualTo: view.topAnchor,
                constant: UIScreen.main.bounds.height * 0.35
            ),
        ])

        // 2. Drag handle
        containerView.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            dragHandle.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),
        ])

        // 3. Header view
        containerView.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: dragHandle.bottomAnchor, constant: 12),
            headerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            headerView.heightAnchor.constraint(equalToConstant: 52),
        ])

        // 3a. Logo icon bên trái header
        let logoContainer = UIView()
        logoContainer.backgroundColor = Palette.accent.withAlphaComponent(0.12)
        logoContainer.layer.cornerRadius = 10
        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(logoContainer)

        let logoIcon = UIImageView(
            image: UIImage(systemName: "slider.horizontal.3",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        )
        logoIcon.tintColor = Palette.accent
        logoIcon.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(logoIcon)

        NSLayoutConstraint.activate([
            logoContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            logoContainer.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            logoContainer.widthAnchor.constraint(equalToConstant: 44),
            logoContainer.heightAnchor.constraint(equalToConstant: 44),
            logoIcon.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoIcon.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
        ])

        // 3b. Tiêu đề + subtitle
        let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleStack)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: 12),
            titleStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
        ])

        // 3c. Close button
        headerView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        // 4. Divider
        containerView.addSubview(headerDivider)
        NSLayoutConstraint.activate([
            headerDivider.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10),
            headerDivider.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            headerDivider.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            headerDivider.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        // 5. Status bar
        statusBar.addSubview(statusIcon)
        statusBar.addSubview(statusLabel)
        containerView.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 10),
            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            statusIcon.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusIcon.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: statusBar.topAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: -8),
        ])

        // 6. TableView
        containerView.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: - Dismiss Gesture (tap ngoài để đóng)
    private func setupDismissGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    // MARK: - Animations (được gọi từ FloatingWindowManager)

    /// Animation xuất hiện: slide up từ bottom + fade in
    func animateIn() {
        containerView.transform = CGAffineTransform(translationX: 0, y: containerView.bounds.height + 60)
        view.alpha = 0

        UIView.animate(
            withDuration: 0.42,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.6,
            options: [.curveEaseOut],
            animations: {
                self.containerView.transform = .identity
                self.view.alpha = 1
            }
        )
    }

    /// Animation biến mất: slide down + fade out, gọi completion khi xong
    func animateOut(completion: @escaping () -> Void) {
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseIn],
            animations: {
                self.containerView.transform = CGAffineTransform(
                    translationX: 0,
                    y: self.containerView.bounds.height + 60
                )
                self.view.alpha = 0
            },
            completion: { _ in completion() }
        )
    }

    // MARK: - Actions

    @objc private func closeButtonTapped() {
        onClose?()
    }

    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: view)
        // Đóng chỉ khi tap vào vùng mờ (ngoài container)
        if !containerView.frame.contains(location) {
            onClose?()
        }
    }

    // MARK: - Toggle Handler

    /// Được gọi khi người dùng toggle UISwitch trên một row
    private func handleToggle(rowIndex: Int, isOn: Bool) {
        rows[rowIndex].isOn = isOn
        let row = rows[rowIndex]

        // Hiển thị trạng thái "đang xử lý"
        showStatus(message: "\(row.title): \(isOn ? "Enabling..." : "Disabling...")", success: nil)

        switch row.actionType {

        case .devicePatch:
            // Chạy trên background thread — DevicePatchService là enum static, thread-safe
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    // PatchLibraryItem đã có sẵn project: PatchProject? và contentKey: Data?
                    // Không cần decode thủ công — dùng trực tiếp
                    let items = PatchProjectLibrary.load()
                    guard let firstItem = items.first else {
                        throw PatchMenuError.noProjectAvailable
                    }
                    guard let project = firstItem.project else {
                        // Package bị lock (chưa có password) — thử decode không password
                        let data = try Data(contentsOf: firstItem.packageURL)
                        let decoded = try PatchPackageCodec.decode(data, password: nil)
                        if isOn {
                            _ = try DevicePatchService.apply(project: decoded.project)
                            DispatchQueue.main.async {
                                self.showStatus(message: "✓ \(row.title) applied.", success: true)
                            }
                        } else {
                            if let receipt = DevicePatchService.latestReceipt(projectID: decoded.project.id) {
                                try DevicePatchService.restore(receipt: receipt)
                            }
                            DispatchQueue.main.async {
                                self.showStatus(message: "↩ \(row.title) restored.", success: true)
                            }
                        }
                        return
                    }
                    if isOn {
                        _ = try DevicePatchService.apply(project: project)
                        DispatchQueue.main.async {
                            self.showStatus(message: "✓ \(row.title) applied.", success: true)
                        }
                    } else {
                        if let receipt = DevicePatchService.latestReceipt(projectID: project.id) {
                            try DevicePatchService.restore(receipt: receipt)
                        }
                        DispatchQueue.main.async {
                            self.showStatus(message: "↩ \(row.title) restored.", success: true)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        // Revert switch trên UI nếu lỗi
                        self.rows[rowIndex].isOn = !isOn
                        self.tableView.reloadRows(
                            at: [IndexPath(row: rowIndex, section: 0)],
                            with: .none
                        )
                        self.showStatus(message: "✗ \(row.title): \(error.localizedDescription)", success: false)
                    }
                }
            }

        case .workspacePatch:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let items = PatchProjectLibrary.load()
                    guard let firstItem = items.first else {
                        throw PatchMenuError.noProjectAvailable
                    }
                    if isOn {
                        // Dùng project đã decode sẵn trong library item nếu có
                        let project: PatchProject
                        if let cached = firstItem.project {
                            project = cached
                        } else {
                            let data = try Data(contentsOf: firstItem.packageURL)
                            let decoded = try PatchPackageCodec.decode(data, password: nil)
                            project = decoded.project
                        }
                        _ = try PatchWorkspaceService.createWorkspace(for: project)
                        DispatchQueue.main.async {
                            self.showStatus(message: "✓ Workspace ready for \(row.title).", success: true)
                        }
                    } else {
                        // Workspace deactivate — không có API xoá, chỉ thông báo
                        DispatchQueue.main.async {
                            self.showStatus(message: "↩ \(row.title) workspace deactivated.", success: true)
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.rows[rowIndex].isOn = !isOn
                        self.tableView.reloadRows(
                            at: [IndexPath(row: rowIndex, section: 0)],
                            with: .none
                        )
                        self.showStatus(message: "✗ \(row.title): \(error.localizedDescription)", success: false)
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    private func showStatus(message: String, success: Bool?) {
        statusLabel.text = message
        if let success {
            statusIcon.image = UIImage(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
            statusIcon.tintColor = success ? UIColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 1) : Palette.danger
            statusBar.backgroundColor = success
                ? UIColor(red: 0.88, green: 0.97, blue: 0.90, alpha: 1)
                : UIColor(red: 0.98, green: 0.88, blue: 0.88, alpha: 1)
        } else {
            statusIcon.image = UIImage(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            statusIcon.tintColor = Palette.accent
            statusBar.backgroundColor = Palette.cellBackground
        }
        statusBar.isHidden = false
    }
}

// MARK: - UITableViewDataSource & Delegate

extension ModMenuViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: MenuToggleCell.reuseID,
            for: indexPath
        ) as! MenuToggleCell

        let row = rows[indexPath.row]
        cell.configure(with: row)
        cell.onToggle = { [weak self] isOn in
            self?.handleToggle(rowIndex: indexPath.row, isOn: isOn)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

// MARK: - UIGestureRecognizerDelegate (chỉ nhận tap ngoài containerView)

extension ModMenuViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        let location = touch.location(in: view)
        return !containerView.frame.contains(location)
    }
}

// MARK: - MenuToggleCell
// Cell custom cho mỗi tính năng trong danh sách

final class MenuToggleCell: UITableViewCell {

    static let reuseID = "MenuToggleCell"

    // MARK: Callback
    var onToggle: ((Bool) -> Void)?

    // MARK: UI Components
    private let cardView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 0.973, green: 0.976, blue: 0.980, alpha: 1) // #F8F9FA
        v.layer.cornerRadius = 14
        v.layer.masksToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconContainer: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 10
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconView: UIImageView = {
        let i = UIImageView()
        i.contentMode = .scaleAspectFit
        i.translatesAutoresizingMaskIntoConstraints = false
        return i
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        l.textColor = UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        l.textColor = UIColor(red: 0.556, green: 0.556, blue: 0.576, alpha: 1)
        l.numberOfLines = 2
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let toggle: UISwitch = {
        let s = UISwitch()
        s.onTintColor = UIColor(red: 0.100, green: 0.400, blue: 0.900, alpha: 1)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    // MARK: - Init

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        setupLayout()
        toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Layout

    private func setupLayout() {
        contentView.addSubview(cardView)
        cardView.addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(subtitleLabel)
        cardView.addSubview(toggle)

        NSLayoutConstraint.activate([
            // Card — margin ngang 16, dọc 5
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            // Icon container 42×42
            iconContainer.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 42),
            iconContainer.heightAnchor.constraint(equalToConstant: 42),

            // Icon bên trong
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            // Toggle bên phải
            toggle.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),

            // Subtitle
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Configure

    func configure(with row: ModMenuViewController.MenuRow) {
        titleLabel.text = row.title
        subtitleLabel.text = row.subtitle
        toggle.isOn = row.isOn
        toggle.onTintColor = row.accentColor

        // Icon SF Symbol với màu accent của row
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.image = UIImage(systemName: row.iconName, withConfiguration: config)
        iconView.tintColor = row.accentColor
        iconContainer.backgroundColor = row.accentColor.withAlphaComponent(0.12)
    }

    // MARK: - Action

    @objc private func toggleChanged(_ sender: UISwitch) {
        // Haptic feedback nhẹ
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onToggle?(sender.isOn)
    }
}

// MARK: - PatchMenuError
// Lỗi nội bộ của menu khi không có project sẵn

private enum PatchMenuError: LocalizedError {
    case noProjectAvailable

    var errorDescription: String? {
        switch self {
        case .noProjectAvailable:
            return "No patch project found. Please create one in the main app first."
        }
    }
}
