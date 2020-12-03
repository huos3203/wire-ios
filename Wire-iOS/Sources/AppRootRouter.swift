//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import UIKit
import WireSyncEngine
import avs

extension AppRootRouter {
    static let appStateDidTransition = Notification.Name(rawValue: "appStateDidTransition")
    static let appStateKey = "AppState"
}

// MARK: - AppRootRouter
public class AppRootRouter: NSObject {
    
    // MARK: - Public Property
    let overlayWindow = NotificationWindow(frame: UIScreen.main.bounds)
    
    // MARK: - Private Property
    private let navigator: NavigatorProtocol
    private var appStateCalculator = AppStateCalculator()
    private var deepLinkURL: URL?
    
    private var authenticationCoordinator: AuthenticationCoordinator?
    private var switchingAccountRouter: SwitchingAccountRouter
    private var urlActionRouter: URLActionRouter
    private var sessionManagerLifeCycleObserver: SessionManagerLifeCycleObserver
    private let foregroundNotificationFilter: ForegroundNotificationFilter
    private var quickActionsManager: QuickActionsManager
    private var authenticatedRouter: AuthenticatedRouter? {
        didSet {
            setupAnalyticsSharing()
        }
    }
    
    private var observerTokens: [NSObjectProtocol] = []
    private var authenticatedBlocks: [() -> Void] = []
    private let teamMetadataRefresher = TeamMetadataRefresher()

    // MARK: - Private Set Property
    private(set) var sessionManager: SessionManager? {
        didSet {
            guard let sessionManager = sessionManager else { return }
            urlActionRouter.sessionManager = sessionManager
            sessionManagerLifeCycleObserver.sessionManager = sessionManager
            foregroundNotificationFilter.sessionManager = sessionManager
            quickActionsManager.sessionManager = sessionManager
            
            sessionManager.foregroundNotificationResponder = foregroundNotificationFilter
            sessionManager.switchingDelegate = switchingAccountRouter
            sessionManager.presentationDelegate = urlActionRouter
            createLifeCycleObserverTokens()
            setCallingSettings()
        }
    }

    //TO DO: This should be private
    private(set) var rootViewController: RootViewController
    
    // MARK: - Initialization
    
    init(viewController: RootViewController,
         navigator: NavigatorProtocol,
         deepLinkURL: URL? = nil) {
        self.rootViewController = viewController
        self.navigator = navigator
        self.deepLinkURL = deepLinkURL
        self.urlActionRouter = URLActionRouter(viewController: viewController,
                                               authenticationCoordinator: authenticationCoordinator,
                                               url: deepLinkURL)
        self.switchingAccountRouter = SwitchingAccountRouter()
        self.quickActionsManager = QuickActionsManager()
        self.foregroundNotificationFilter = ForegroundNotificationFilter()
        self.sessionManagerLifeCycleObserver = SessionManagerLifeCycleObserver()
        super.init()
        
        setupAppStateCalculator()
        setupNotifications()
        setupAdditionalWindows()
        
        AppRootRouter.configureAppearance()
    }
    
    // MARK: - Public implementation
    
    public func start(launchOptions: LaunchOptions) {
        transition(to: .headless, completion: {
            Analytics.shared.tagEvent("app.open")
        })
        createAndStartSessionManager(launchOptions: launchOptions)
    }
    
    public func openDeepLinkURL(_ deepLinkURL: URL?) -> Bool {
        guard let url = deepLinkURL else { return false }
        return urlActionRouter.open(url: url)
    }
    
    public func performQuickAction(for shortcutItem: UIApplicationShortcutItem,
                                   completionHandler: ((Bool)->())?) {
        quickActionsManager.performAction(for: shortcutItem,
                                          completionHandler: completionHandler)
    }
    
    // MARK: - Private implementation
    private func setupAppStateCalculator() {
        appStateCalculator.delegate = self
    }
    
    private func setupNotifications() {
        setupApplicationNotifications()
        setupContentSizeCategoryNotifications()
        setupAudioPermissionsNotifications()
    }
    
    private func setupAdditionalWindows() {
        overlayWindow.makeKeyAndVisible()
        overlayWindow.isHidden = true
    }
    
    private func createLifeCycleObserverTokens() {
        sessionManagerLifeCycleObserver.createLifeCycleObserverTokens()
    }
    
    private func createAndStartSessionManager(launchOptions: LaunchOptions) {
        guard
            let appVersion = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] as? String,
            let url = Bundle.main.url(forResource: "session_manager", withExtension: "json"),
            let configuration = SessionManagerConfiguration.load(from: url),
            let mediaManager = AVSMediaManager.sharedInstance()
        else {
            return
        }
        
        configuration.blacklistDownloadInterval = Settings.shared.blacklistDownloadInterval
        let jailbreakDetector = JailbreakDetector()
        
        SessionManager.clearPreviousBackups()
        SessionManager.create(appVersion: appVersion,
                              mediaManager: mediaManager,
                              analytics: Analytics.shared,
                              delegate: appStateCalculator,
                              presentationDelegate: urlActionRouter,
                              application: UIApplication.shared,
                              environment: BackendEnvironment.shared,
                              configuration: configuration,
                              detector: jailbreakDetector) { [weak self] sessionManager in
                self?.sessionManager = sessionManager
                self?.sessionManager?.start(launchOptions: launchOptions)
                self?.urlActionRouter.openDeepLink(needsAuthentication: false)
        }
    }
    
    private func setCallingSettings() {
        sessionManager?.updateCallNotificationStyleFromSettings()
        sessionManager?.useConstantBitRateAudio = SecurityFlags.forceConstantBitRateCalls.isEnabled
            ? true
            : Settings.shared[.callingConstantBitRate] ?? false
    }
}

// MARK: - AppStateCalculatorDelegate
extension AppRootRouter: AppStateCalculatorDelegate {
    func appStateCalculator(_: AppStateCalculator,
                            didCalculate appState: AppState,
                            completion: @escaping () -> Void) {
        applicationWillTransition(to: appState)
        transition(to: appState, completion: completion)
        notifyTransition(for: appState)
    }
    
    private func notifyTransition(for appState: AppState) {
        NotificationCenter.default.post(name: AppRootRouter.appStateDidTransition,
                                        object: nil,
                                        userInfo: [AppRootRouter.appStateKey: appState])
    }
    
    private func transition(to appState: AppState, completion: @escaping () -> Void) {
        resetAuthenticationCoordinatorIfNeeded(for: appState)
        
        let completionBlock = { [weak self] in
            completion()
            self?.applicationDidTransition(to: appState)
        }
        
        switch appState {
        case .blacklisted:
            showBlacklisted(completion: completionBlock)
        case .jailbroken:
            showJailbroken(completion: completionBlock)
        case .migrating:
            showLaunchScreen(isLoading: true, completion: completionBlock)
        case .unauthenticated(error: let error):
            configureUnauthenticatedAppearance()
            showUnauthenticatedFlow(error: error, completion: completionBlock)
        case .authenticated(completedRegistration: let completedRegistration, isDatabaseLocked: _):
            configureAuthenticatedAppearance()
            executeAuthenticatedBlocks()
            showAuthenticated(isComingFromRegistration: completedRegistration,
                              completion: completionBlock)
        case .headless:
            showLaunchScreen(completion: completionBlock)
        case .loading(account: let toAccount, from: let fromAccount):
            showSkeleton(fromAccount: fromAccount,
                         toAccount: toAccount,
                         completion: completionBlock)
        }
    }
    
    private func resetAuthenticationCoordinatorIfNeeded(for state: AppState) {
        switch state {
        case .unauthenticated:
            break // do not reset the authentication coordinator for unauthenticated state
        default:
            authenticationCoordinator = nil // reset the authentication coordinator when we no longer need it
        }
    }
    
    func performWhenAuthenticated(_ block : @escaping () -> Void) {
        if case .authenticated = appStateCalculator.appState {
            block()
        } else {
            authenticatedBlocks.append(block)
        }
    }

    func executeAuthenticatedBlocks() {
        while !authenticatedBlocks.isEmpty {
            authenticatedBlocks.removeFirst()()
        }
    }

    func reload() {
        transition(to: .headless, completion: { })
        transition(to: appStateCalculator.appState, completion: { })
    }
}

extension AppRootRouter {
    // MARK: - Navigation Helpers
    private func showBlacklisted(completion: @escaping () -> Void) {
        let blockerViewController = BlockerViewController(context: .blacklist)
        rootViewController.set(childViewController: blockerViewController,
                               completion: completion)
    }
    
    private func showJailbroken(completion: @escaping () -> Void) {
        let blockerViewController = BlockerViewController(context: .jailbroken)
        rootViewController.set(childViewController: blockerViewController,
                               completion: completion)
    }
    
    private func showLaunchScreen(isLoading: Bool = false, completion: @escaping () -> Void) {
        let launchViewController = LaunchImageViewController()
        isLoading
            ? launchViewController.showLoadingScreen()
            : ()
        rootViewController.set(childViewController: launchViewController,
                               completion: completion)
    }
    
    private func showUnauthenticatedFlow(error: NSError?, completion: @escaping () -> Void) {
        // Only execute handle events if there is no current flow
        guard
            self.authenticationCoordinator == nil ||
                error?.userSessionErrorCode == .addAccountRequested ||
                error?.userSessionErrorCode == .accountDeleted,
            let sessionManager = SessionManager.shared
        else {
            return
        }
        
        let navigationController = SpinnerCapableNavigationController(navigationBarClass: AuthenticationNavigationBar.self,
                                                                      toolbarClass: nil)
        
        authenticationCoordinator = AuthenticationCoordinator(presenter: navigationController,
                                                              sessionManager: sessionManager,
                                                              featureProvider: BuildSettingAuthenticationFeatureProvider(),
                                                              statusProvider: AuthenticationStatusProvider())
        
        guard let authenticationCoordinator = authenticationCoordinator else {
            return
        }
        
        authenticationCoordinator.delegate = appStateCalculator
        authenticationCoordinator.startAuthentication(with: error,
                                                      numberOfAccounts: SessionManager.numberOfAccounts)
        
        rootViewController.set(childViewController: navigationController,
                               completion: completion)
    }
    
    private func showAuthenticated(isComingFromRegistration: Bool, completion: @escaping () -> Void) {
        guard
            let selectedAccount = SessionManager.shared?.accountManager.selectedAccount,
            let authenticatedRouter = buildAuthenticatedRouter(account: selectedAccount,
                                                               isComingFromRegistration: isComingFromRegistration)
        else {
            return
        }
        
        self.authenticatedRouter = authenticatedRouter
        
        rootViewController.set(childViewController: authenticatedRouter.viewController,
                               completion: completion)
    }
    
    private func showSkeleton(fromAccount: Account?, toAccount: Account, completion: @escaping () -> Void) {
        let skeletonViewController = SkeletonViewController(from: fromAccount, to: toAccount)
        rootViewController.set(childViewController: skeletonViewController,
                               completion: completion)
    }
    
    // MARK: - Helpers
    private func configureUnauthenticatedAppearance() {
        rootViewController.view.window?.tintColor = UIColor.Wire.primaryLabel
        AccessoryTextField.appearance(whenContainedInInstancesOf: [AuthenticationStepController.self]).tintColor = UIColor.Team.activeButton
    }
    
    private func configureAuthenticatedAppearance() {
        rootViewController.view.window?.tintColor = .accent()
        UIColor.setAccentOverride(.undefined)
    }
    
    private func setupAnalyticsSharing() {
        Analytics.shared.selfUser = SelfUser.current
        
        guard
            appStateCalculator.wasUnauthenticated,
            Analytics.shared.selfUser?.isTeamMember ?? false
        else {
            return
        }
        
        TrackingManager.shared.disableCrashSharing = true
        TrackingManager.shared.disableAnalyticsSharing = false
    }
    
    private func buildAuthenticatedRouter(account: Account,
                                           isComingFromRegistration: Bool) -> AuthenticatedRouter? {
        
        let needToShowDataUsagePermissionDialog = appStateCalculator.wasUnauthenticated
                                                    && !SelfUser.current.isTeamMember
        
        return AuthenticatedRouter(rootViewController: rootViewController,
                                   account: account,
                                   selfUser: ZMUser.selfUser(),
                                   isComingFromRegistration: isComingFromRegistration,
                                   needToShowDataUsagePermissionDialog: needToShowDataUsagePermissionDialog)
    }
}

// TO DO: THIS PART MUST BE CLENED UP
extension AppRootRouter {
    private func applicationWillTransition(to appState: AppState) {
        if case .authenticated = appState {
            if AppDelegate.shared.shouldConfigureSelfUserProvider {
                SelfUser.provider = ZMUserSession.shared()
            }
        }
        
        let colorScheme = ColorScheme.default
        colorScheme.accentColor = .accent()
        colorScheme.variant = Settings.shared.colorSchemeVariant
    }
    
    private func applicationDidTransition(to appState: AppState) {
        if case .authenticated = appState {
            authenticatedRouter?.updateActiveCallPresentationState()
            urlActionRouter.openDeepLink(needsAuthentication: true)
            ZClientViewController.shared?.legalHoldDisclosureController?.discloseCurrentState(cause: .appOpen)
        } else if AppDelegate.shared.shouldConfigureSelfUserProvider {
            SelfUser.provider = nil
        }
        
        presentAlertForDeletedAccount(appState)
    }
    
    private func presentAlertForDeletedAccount(_ appState: AppState) {
        guard
            case .unauthenticated(let error) = appState,
            error?.userSessionErrorCode == .accountDeleted,
            let reason = error?.userInfo[ZMAccountDeletedReasonKey] as? ZMAccountDeletedReason
        else {
            return
        }
    
        switch reason {
        case .sessionExpired:
            rootViewController.presentAlertWithOKButton(title: "account_deleted_session_expired_alert.title".localized,
                                                        message: "account_deleted_session_expired_alert.message".localized)
        default:
            break
        }
    }
}

// MARK: - ApplicationStateObserving
extension AppRootRouter: ApplicationStateObserving {
    func addObserverToken(_ token: NSObjectProtocol) {
        observerTokens.append(token)
    }
    
    func applicationDidBecomeActive() {
        updateOverlayWindowFrame()
        teamMetadataRefresher.triggerRefreshIfNeeded()
    }
    
    func applicationDidEnterBackground() {
        let unreadConversations = sessionManager?.accountManager.totalUnreadCount ?? 0
        UIApplication.shared.applicationIconBadgeNumber = unreadConversations
    }
    
    func applicationWillEnterForeground() {
        updateOverlayWindowFrame()
    }
    
    func updateOverlayWindowFrame(size: CGSize? = nil) {
        if let size = size {
            overlayWindow.frame.size = size
        } else {
            overlayWindow.frame = UIApplication.shared.keyWindow?.frame ?? UIScreen.main.bounds
        }
    }
}

// MARK: - ContentSizeCategoryObserving
extension AppRootRouter: ContentSizeCategoryObserving {
    func contentSizeCategoryDidChange() {
        NSAttributedString.invalidateParagraphStyle()
        NSAttributedString.invalidateMarkdownStyle()
        ConversationListCell.invalidateCachedCellSize()
        defaultFontScheme = FontScheme(contentSizeCategory: UIApplication.shared.preferredContentSizeCategory)
        AppRootRouter.configureAppearance()
    }
    
    public static func configureAppearance() {
        let navigationBarTitleBaselineOffset: CGFloat = 2.5
        
        let attributes: [NSAttributedString.Key : Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .baselineOffset: navigationBarTitleBaselineOffset]
        let barButtonItemAppearance = UIBarButtonItem.appearance(whenContainedInInstancesOf: [DefaultNavigationBar.self])
        barButtonItemAppearance.setTitleTextAttributes(attributes, for: .normal)
        barButtonItemAppearance.setTitleTextAttributes(attributes, for: .highlighted)
        barButtonItemAppearance.setTitleTextAttributes(attributes, for: .disabled)
    }
}

// MARK: - AudioPermissionsObserving
extension AppRootRouter: AudioPermissionsObserving {
    func userDidGrantAudioPermissions() {
        sessionManager?.updateCallNotificationStyleFromSettings()
    }
}


protocol AuthenticatedRouterProtocol: class {
    func updateActiveCallPresentationState()
    func minimizeCallOverlay(animated: Bool, withCompletion completion: Completion?)
}

// MARK: - Class AuthenticatedRouter

class AuthenticatedRouter: NSObject {
    
    // MARK: - Private Property
    
    private let builder: AuthenticatedWireFrame
    private let rootViewController: RootViewController
    private let activeCallRouter: ActiveCallRouter
    private weak var _viewController: ZClientViewController?
    
    // MARK: - Public Property

    var viewController: UIViewController {
        let viewController = _viewController ?? builder.build(router: self)
        _viewController = viewController
        return viewController
    }
    
    // MARK: - Init
    
    init(rootViewController: RootViewController,
         account: Account,
         selfUser: SelfUserType,
         isComingFromRegistration: Bool,
         needToShowDataUsagePermissionDialog: Bool) {
        
        self.rootViewController = rootViewController
        activeCallRouter = ActiveCallRouter(rootviewController: rootViewController)
        
        builder = AuthenticatedWireFrame(account: account,
                                         selfUser: selfUser,
                                         isComingFromRegistration: needToShowDataUsagePermissionDialog,
                                         needToShowDataUsagePermissionDialog: needToShowDataUsagePermissionDialog)
    }
}

// MARK: - AuthenticatedRouterProtocol
extension AuthenticatedRouter: AuthenticatedRouterProtocol {
    func updateActiveCallPresentationState() {
        activeCallRouter.updateActiveCallPresentationState()
    }
    
    func minimizeCallOverlay(animated: Bool,
                             withCompletion completion: Completion?) {
        activeCallRouter.minimizeCall(animated: animated, completion: completion)
    }
}

// MARK: - AuthenticatedWireFrame
struct AuthenticatedWireFrame {
    private var account: Account
    private var selfUser: SelfUserType
    private var isComingFromRegistration: Bool
    private var needToShowDataUsagePermissionDialog: Bool
    
    init(account: Account,
         selfUser: SelfUserType,
         isComingFromRegistration: Bool,
         needToShowDataUsagePermissionDialog: Bool) {
        self.account = account
        self.selfUser = selfUser
        self.isComingFromRegistration = isComingFromRegistration
        self.needToShowDataUsagePermissionDialog = needToShowDataUsagePermissionDialog
    }
    
    func build(router: AuthenticatedRouterProtocol) -> ZClientViewController {
        let viewController = ZClientViewController(account: account, selfUser: selfUser)
        viewController.isComingFromRegistration = isComingFromRegistration
        viewController.needToShowDataUsagePermissionDialog = needToShowDataUsagePermissionDialog
        viewController.router =  router
        return viewController
    }
}