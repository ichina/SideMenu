//
//  UISideMenuNavigationController.swift
//
//  Created by Jon Kent on 1/14/16.
//  Copyright © 2016 Jon Kent. All rights reserved.
//

import UIKit

@objc public enum MenuPushStyle: Int { case
    `default`,
    popWhenPossible,
    preserve,
    preserveAndHideBackButton,
    replace,
    subMenu
}

@objc public protocol UISideMenuNavigationControllerDelegate {
    @objc optional func sideMenuWillAppear(menu: UISideMenuNavigationController, animated: Bool)
    @objc optional func sideMenuDidAppear(menu: UISideMenuNavigationController, animated: Bool)
    @objc optional func sideMenuWillDisappear(menu: UISideMenuNavigationController, animated: Bool)
    @objc optional func sideMenuDidDisappear(menu: UISideMenuNavigationController, animated: Bool)
}

internal protocol UISideMenuNavigationControllerTransitionDelegate: class {
    func sideMenuTransitionDidDismiss(menu: Menu)
}

public struct SideMenuSettings: MenuModel {
    public var allowPushOfSameClassTwice: Bool = true
    public var alwaysAnimate: Bool = true
    public var animationOptions: UIView.AnimationOptions = .curveEaseInOut
    public var blurEffectStyle: UIBlurEffect.Style? = nil
    public var completeGestureDuration: Double = 0.35
    public var completionCurve: UIView.AnimationCurve = .easeIn
    public var dismissDuration: Double = 0.35
    public var dismissOnPresent: Bool = true
    public var dismissOnPush: Bool = true
    public var dismissWhenBackgrounded: Bool = true
    public var enableSwipeGestures: Bool = true
    public var statusBarEndAlpha: CGFloat = 1
    public var initialSpringVelocity: CGFloat = 1
    public var menuWidth: CGFloat = {
        let appScreenRect = UIApplication.shared.keyWindow?.bounds ?? UIWindow().bounds
        let minimumSize = min(appScreenRect.width, appScreenRect.height)
        return min(round(minimumSize * 0.75), 240)
    }()
    public var presentingViewControllerUserInteractionEnabled: Bool = false
    public var presentingViewControllerUseSnapshot: Bool = true
    public var presentDuration: Double = 0.35
    public var presentStyle: SideMenuPresentStyle = .viewSlideOut
    public var pushStyle: MenuPushStyle = .default
    public var usingSpringWithDamping: CGFloat = 1

    public init() {}

    public init(_ block: (inout SideMenuSettings) -> Void) {
        self.init()
        block(&self)
    }
}

internal typealias Menu = UISideMenuNavigationController

@objcMembers
open class UISideMenuNavigationController: UINavigationController {

    private enum PropertyName: String { case
        leftSide
    }

    private lazy var _leftSide = Protected(false,
                                           if: { [weak self] _ in self?.isHidden != false },
                                           else: { _ in Menu.elseCondition(.leftSide) } )

    private weak var _sideMenuManager: SideMenuManager?
    private weak var foundDelegate: UISideMenuNavigationControllerDelegate?
    private weak var interactionController: SideMenuInteractionController?
    private var interactive: Bool = false
    private var originalBackgroundColor: UIColor?
    private var rotating: Bool = false
    private var transitionController: SideMenuTransitionController?

    /// Delegate for receiving appear and disappear related events. If `nil` the visible view controller that displays a `UISideMenuNavigationController` automatically receives these events.
    internal weak var sideMenuDelegate: UISideMenuNavigationControllerDelegate?

    /// The swipe to dismiss gesture.
    private(set) weak var swipeToDismissGesture: UIPanGestureRecognizer? = nil

    open var sideMenuManager: SideMenuManager {
        get { return _sideMenuManager ?? SideMenuManager.default }
        set {
            newValue.setMenu(self, forLeftSide: leftSide)

            if let sideMenuManager = _sideMenuManager, sideMenuManager !== newValue {
                let side = SideMenuManager.PresentDirection(leftSide: leftSide)
                Print.warning(.menuAlreadyAssigned, arguments: String(describing: self.self), side.name, String(describing: newValue))
            }
            _sideMenuManager = newValue
        }
    }

    open var settings = SideMenuSettings() {
        didSet {
            setupBlur()
            setupSwipeGestures()
        }
    }

    #if !STFU_SIDEMENU
    // This override prevents newbie developers from creating black/blank menus and opening newbie issues.
    // If you would like to remove this override, define STFU_SIDEMENU in the Active Compilation Conditions of your .plist file.
    // Sorry for the inconvenience experienced developers :(
    @available(*, unavailable, renamed: "init(rootViewController:)")
    init() {
        fatalError("init is not available")
    }

    #else

    public init(_ block: (UISideMenuNavigationController) -> Void) {
        self.init()
        block(self)
    }

    #endif

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    override open func awakeFromNib() {
        super.awakeFromNib()
        sideMenuManager.setMenu(self, forLeftSide: leftSide)
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if topViewController == nil {
            Print.warning(.emptyMenu)
        }

        // Dismiss keyboard to prevent weird keyboard animations from occurring during transition
        presentingViewController?.view.endEditing(true)

        foundDelegate = nil
        activeDelegate?.sideMenuWillAppear?(menu: self, animated: animated)
    }
    
    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // We had presented a view before, so lets dismiss ourselves as already acted upon
        if view.isHidden {
            transitionController?.transition(presenting: false, animated: false)
            dismiss(animated: false, completion: { [weak self] in
                self?.view.isHidden = false
            })
        } else {
            activeDelegate?.sideMenuDidAppear?(menu: self, animated: animated)
        }
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // When presenting a view controller from the menu, the menu view gets moved into another transition view above our transition container
        // which can break the visual layout we had before. So, we move the menu view back to its original transition view to preserve it.
        if dismissOnPresent && !isBeingDismissed {
            // We're presenting a view controller from the menu, so we need to hide the menu so it isn't showing when the presented view is dismissed.
            if let presentingView = presentingViewController?.view, let containerView = presentingView.superview {
                containerView.addSubview(view)
            }

            transitionController?.transition(presenting: false, animated: animated, alongsideTransition: { [weak self] in
                guard let self = self else { return }
                self.activeDelegate?.sideMenuWillDisappear?(menu: self, animated: animated)
            }, complete: false, completion: { [weak self] _ in
                guard let self = self else { return }
                self.activeDelegate?.sideMenuDidDisappear?(menu: self, animated: animated)
                self.view.isHidden = true
            })
        } else {
            activeDelegate?.sideMenuWillDisappear?(menu: self, animated: animated)
        }
    }

    override open func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        // Work-around: if the menu is dismissed without animation the transition logic is never called to restore the
        // the view hierarchy leaving the screen black/empty. This is because the transition moves views within a container
        // view, but dismissing without animation removes the container view before the original hierarchy is restored.
        // This check corrects that.
        if let activeDelegate = activeDelegate as? UIViewController, activeDelegate.view.window == nil {
            transitionController?.transition(presenting: false, animated: false)
        }

        // Clear selecton on UITableViewControllers when reappearing using custom transitions
        if let tableViewController = topViewController as? UITableViewController,
            let tableView = tableViewController.tableView,
            let indexPaths = tableView.indexPathsForSelectedRows,
            tableViewController.clearsSelectionOnViewWillAppear {
            indexPaths.forEach { tableView.deselectRow(at: $0, animated: false) }
        }

        activeDelegate?.sideMenuDidDisappear?(menu: self, animated: animated)

        if dismissOnPresent && !isBeingDismissed {
            view.isHidden = true
        } else {
            transitionController = nil
        }
    }
    
    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        // Don't bother resizing if the view isn't visible
        guard let transitionController = transitionController, !view.isHidden else { return }

        rotating = true
        
        let presentingViewControllerUseSnapshot = self.presentingViewControllerUseSnapshot
        coordinator.animate(alongsideTransition: { _ in
            if presentingViewControllerUseSnapshot {
                transitionController.transition(presenting: false, animated: false, complete: false)
            } else {
                transitionController.layout()
            }
        }) { [weak self] _ in
            guard let self = self else { return }
            if presentingViewControllerUseSnapshot {
                self.dismissMenu(animated: false)
            }
            self.rotating = false
        }
    }
    
    override open func pushViewController(_ viewController: UIViewController, animated: Bool) {
        let push = shouldPushViewController(viewController: viewController, animated: animated) { [weak self] _ in
            self?.foundDelegate = nil
        }
        
        if push {
            super.pushViewController(viewController, animated: animated)
        }
    }

    override open var transitioningDelegate: UIViewControllerTransitioningDelegate? {
        get { return self }
        set { Print.warning(.transitioningDelegate, required: true) }
    }
}

// Interface
extension UISideMenuNavigationController: MenuModel {

    @IBInspectable open var allowPushOfSameClassTwice: Bool {
        get { return settings.allowPushOfSameClassTwice }
        set { settings.allowPushOfSameClassTwice = newValue }
    }

    @IBInspectable open var alwaysAnimate: Bool {
        get { return settings.alwaysAnimate }
        set { settings.alwaysAnimate = newValue }
    }

    @IBInspectable open var animationOptions: UIView.AnimationOptions {
        get { return settings.animationOptions }
        set { settings.animationOptions = newValue }
    }

    open var blurEffectStyle: UIBlurEffect.Style? {
        get { return settings.blurEffectStyle }
        set { settings.blurEffectStyle = newValue }
    }

    @IBInspectable open var completeGestureDuration: Double {
        get { return settings.completeGestureDuration }
        set { settings.completeGestureDuration = newValue }
    }

    @IBInspectable open var completionCurve: UIView.AnimationCurve {
        get { return settings.completionCurve }
        set { settings.completionCurve = newValue }
    }

    @IBInspectable open var dismissDuration: Double {
        get { return settings.dismissDuration }
        set { settings.dismissDuration = newValue }
    }

    @IBInspectable open var dismissOnPresent: Bool {
        get { return settings.dismissOnPresent }
        set { settings.dismissOnPresent = newValue }
    }

    @IBInspectable open var dismissOnPush: Bool {
        get { return settings.dismissOnPush }
        set { settings.dismissOnPush = newValue }
    }

    @IBInspectable open var dismissWhenBackgrounded: Bool {
        get { return settings.dismissWhenBackgrounded }
        set { settings.dismissWhenBackgrounded = newValue }
    }

    @IBInspectable open var enableSwipeGestures: Bool {
        get { return settings.enableSwipeGestures }
        set { settings.enableSwipeGestures = newValue }
    }

    @IBInspectable open var initialSpringVelocity: CGFloat {
        get { return settings.initialSpringVelocity }
        set { settings.initialSpringVelocity = newValue }
    }

    /// Whether the menu appears on the right or left side of the screen. Right is the default. This property cannot be changed after the menu has loaded.
    @IBInspectable open var leftSide: Bool {
        get { return _leftSide.value }
        set { _leftSide.value = newValue }
    }

    @IBInspectable open var menuWidth: CGFloat {
        get { return settings.menuWidth }
        set { settings.menuWidth = newValue }
    }

    @IBInspectable open var presentingViewControllerUserInteractionEnabled: Bool {
        get { return settings.presentingViewControllerUserInteractionEnabled }
        set { settings.presentingViewControllerUserInteractionEnabled = newValue }
    }

    @IBInspectable open var presentingViewControllerUseSnapshot: Bool {
        get { return settings.presentingViewControllerUseSnapshot }
        set { settings.presentingViewControllerUseSnapshot = newValue }
    }

    @IBInspectable open var presentDuration: Double {
        get { return settings.presentDuration }
        set { settings.presentDuration = newValue }
    }

    open var presentStyle: SideMenuPresentStyle {
        get { return settings.presentStyle }
        set { settings.presentStyle = newValue }
    }

    @IBInspectable open var pushStyle: MenuPushStyle {
        get { return settings.pushStyle }
        set { settings.pushStyle = newValue }
    }

    @IBInspectable open var statusBarEndAlpha: CGFloat {
        get { return settings.statusBarEndAlpha }
        set { settings.statusBarEndAlpha = newValue }
    }

    @IBInspectable open var usingSpringWithDamping: CGFloat {
        get { return settings.usingSpringWithDamping }
        set { settings.usingSpringWithDamping = newValue }
    }
}

// IMPORTANT: These methods must be declared open or they will not be called.
extension UISideMenuNavigationController: UIViewControllerTransitioningDelegate {

    open func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        transitionController = SideMenuTransitionController(
            config: self,
            leftSide: leftSide,
            delegate: self)
        return transitionController
    }

    open func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return transitionController
    }

    open func interactionControllerForPresentation(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return interactionController(using: animator)
    }

    open func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return interactionController(using: animator)
    }

    open func interactionController(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        guard interactive else { return nil }
        let interactionController = SideMenuInteractionController(cancelWhenBackgrounded: dismissWhenBackgrounded, completionCurve: completionCurve)
        self.interactionController = interactionController
        return interactionController
    }
}

extension UISideMenuNavigationController: SideMenuTransitionControllerDelegate {

    internal func sideMenuTransitionController(_ transitionController: SideMenuTransitionController, didDismiss viewController: UIViewController) {
        sideMenuManager.sideMenuTransitionDidDismiss(menu: self)
    }

    internal func sideMenuTransitionController(_ transitionController: SideMenuTransitionController, didPresent viewController: UIViewController) {
        guard !presentingViewControllerUserInteractionEnabled else { return }

        let panGesture = UIPanGestureRecognizer()
        panGesture.cancelsTouchesInView = false
        panGesture.addTarget(self, action: #selector(handleDismissMenuPan(_:)))
        view.superview?.addGestureRecognizer(panGesture)

        let tapGestureRecognizer = UITapGestureRecognizer()
        tapGestureRecognizer.addTarget(self, action: #selector(handleDismissMenuTap(_:)))
        tapGestureRecognizer.cancelsTouchesInView = false
        view.superview?.addGestureRecognizer(tapGestureRecognizer)
    }
}

internal extension UISideMenuNavigationController {

    func handleMenuPan(_ gesture: UIPanGestureRecognizer, _ presenting: Bool) {
        let width = menuWidth
        let distance = gesture.xTranslation / width
        let progress = max(min(distance * factor(presenting), 1), 0)
        switch (gesture.state) {
        case .began:
            if !presenting {
                dismissMenu(interactively: true)
            }
            interactionController?.handle(state: .update(progress: progress))
        case .changed:
            interactionController?.handle(state: .update(progress: progress))
        case .ended:
            let velocity = gesture.xVelocity * factor(presenting)
            let finished = velocity >= 100 || velocity >= -50 && abs(progress) >= 0.5
            interactionController?.handle(state: finished ? .finish : .cancel)
        default:
            interactionController?.handle(state: .cancel)
        }
    }

    func cancelMenuPan(_ gesture: UIPanGestureRecognizer) {
        interactionController?.handle(state: .cancel)
    }

    func dismissMenu(animated flag: Bool = true, interactively interactive: Bool = false, completion: (() -> Void)? = nil) {
        guard !isHidden else { return }
        self.interactive = interactive
        dismiss(animated: flag, completion: completion)
    }

    // Note: although this method is syntactically reversed it allows the interactive property to scoped privately
    func presentFrom(_ viewControllerToPresentFrom: UIViewController?, interactively interactive: Bool, completion: (() -> Void)? = nil) {
        guard let viewControllerToPresentFrom = viewControllerToPresentFrom else { return }
        self.interactive = interactive
        viewControllerToPresentFrom.present(self, animated: true, completion: completion)
    }
}

private extension UISideMenuNavigationController {

    func shouldPushViewController(viewController: UIViewController, animated: Bool, completion: ((Bool) -> Void)?) -> Bool {
        guard viewControllers.count > 0 && pushStyle != .subMenu else {
            // NOTE: pushViewController is called by init(rootViewController: UIViewController)
            // so we must perform the normal super method in this case
            return true
        }

        let splitViewController = presentingViewController as? UISplitViewController
        let tabBarController = presentingViewController as? UITabBarController
        let potentialNavigationController = (splitViewController?.viewControllers.first ?? tabBarController?.selectedViewController) ?? presentingViewController
        guard let navigationController = potentialNavigationController as? UINavigationController else {
            Print.warning(.cannotPush, arguments: String(describing: potentialNavigationController.self), required: true)
            return false
        }

        // To avoid overlapping dismiss & pop/push calls, create a transaction block where the menu
        // is dismissed after showing the appropriate screen
        CATransaction.begin()
        defer { CATransaction.commit() }
        var push = false

        if dismissOnPush {
            let animated = animated || alwaysAnimate
            if animated {
                let areAnimationsEnabled = UIView.areAnimationsEnabled
                UIView.setAnimationsEnabled(true)
                transitionController?.transition(presenting: false, animated: animated, alongsideTransition: { [weak self] in
                    guard let self = self else { return }
                    self.activeDelegate?.sideMenuWillDisappear?(menu: self, animated: animated)
                    }, completion: { [weak self] _ in
                        guard let self = self else { return }
                        self.activeDelegate?.sideMenuDidDisappear?(menu: self, animated: animated)
                        self.dismiss(animated: false, completion: nil)
                        completion?(push)
                })
                UIView.setAnimationsEnabled(areAnimationsEnabled)
            }
        }

        if let lastViewController = navigationController.viewControllers.last,
            !allowPushOfSameClassTwice && type(of: lastViewController) == type(of: viewController) {
            return false
        }

        switch pushStyle {
        case .subMenu: return false // handled earlier
        case .default:
            navigationController.pushViewController(viewController, animated: animated)
            return false
        case .popWhenPossible:
            for subViewController in navigationController.viewControllers.reversed() {
                if type(of: subViewController) == type(of: viewController) {
                    navigationController.popToViewController(subViewController, animated: animated)
                    return false
                }
            }
            push = true
            return true
        case .preserve, .preserveAndHideBackButton:
            var viewControllers = navigationController.viewControllers
            let filtered = viewControllers.filter { preservedViewController in type(of: preservedViewController) == type(of: viewController) }
            if let preservedViewController = filtered.last {
                viewControllers = viewControllers.filter { subViewController in subViewController !== preservedViewController }
                if pushStyle == .preserveAndHideBackButton {
                    preservedViewController.navigationItem.hidesBackButton = true
                }
                viewControllers.append(preservedViewController)
                navigationController.setViewControllers(viewControllers, animated: animated)
                return false
            }
            if pushStyle == .preserveAndHideBackButton {
                viewController.navigationItem.hidesBackButton = true
            }

            push = true
            return true
        case .replace:
            viewController.navigationItem.hidesBackButton = true
            navigationController.setViewControllers([viewController], animated: animated)
            return false
        }
    }

    private class func elseCondition(_ propertyName: PropertyName) {
        Print.warning(.property, arguments: propertyName.rawValue, required: true)
    }

    weak var activeDelegate: UISideMenuNavigationControllerDelegate? {
        guard !view.isHidden else { return nil }
        return sideMenuDelegate ?? foundDelegate ?? findDelegate(forViewController: presentingViewController)
    }

    func findDelegate(forViewController: UIViewController?) -> UISideMenuNavigationControllerDelegate? {
        if let navigationController = forViewController as? UINavigationController {
            return findDelegate(forViewController: navigationController.topViewController)
        }
        if let tabBarController = forViewController as? UITabBarController {
            return findDelegate(forViewController: tabBarController.selectedViewController)
        }
        if let splitViewController = forViewController as? UISplitViewController {
            return findDelegate(forViewController: splitViewController.viewControllers.last)
        }

        foundDelegate = forViewController as? UISideMenuNavigationControllerDelegate
        return foundDelegate
    }

    func setup() {
        modalPresentationStyle = .custom

        setupBlur()
        setupSwipeGestures()
        registerForNotifications()
    }

    func setupBlur() {
        removeBlur()

        guard let blurEffectStyle = blurEffectStyle,
            let view = topViewController?.view,
            !UIAccessibility.isReduceTransparencyEnabled else {
                return
        }

        originalBackgroundColor = originalBackgroundColor ?? view.backgroundColor

        let blurEffect = UIBlurEffect(style: blurEffectStyle)
        let blurView = UIVisualEffectView(effect: blurEffect)
        view.backgroundColor = UIColor.clear
        if let tableViewController = topViewController as? UITableViewController {
            tableViewController.tableView.backgroundView = blurView
            tableViewController.tableView.separatorEffect = UIVibrancyEffect(blurEffect: blurEffect)
            tableViewController.tableView.reloadData()
        } else {
            blurView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
            blurView.frame = view.bounds
            view.insertSubview(blurView, at: 0)
        }
    }

    func removeBlur() {
        guard let originalBackgroundColor = originalBackgroundColor,
            let view = topViewController?.view else {
                return
        }

        self.originalBackgroundColor = nil
        view.backgroundColor = originalBackgroundColor

        if let tableViewController = topViewController as? UITableViewController {
            tableViewController.tableView.backgroundView = nil
            tableViewController.tableView.separatorEffect = nil
            tableViewController.tableView.reloadData()
        } else if let blurView = view.subviews.first as? UIVisualEffectView {
            blurView.removeFromSuperview()
        }
    }

    func setupSwipeGestures() {
        if let swipeToDismissGesture = swipeToDismissGesture {
            swipeToDismissGesture.view?.removeGestureRecognizer(swipeToDismissGesture)
        }
        if enableSwipeGestures {
            swipeToDismissGesture = addDismissPanGesture(to: view)
        }
    }

    func registerForNotifications() {
        NotificationCenter.default.removeObserver(self)

        [UIApplication.willChangeStatusBarFrameNotification,
        UIApplication.didEnterBackgroundNotification].forEach {
            NotificationCenter.default.addObserver(self, selector: #selector(handleNotification), name: $0, object: nil)
        }
    }

    @objc func handleNotification(notification: NSNotification) {
        guard isHidden else { return }

        switch notification.name {
        case UIApplication.willChangeStatusBarFrameNotification:
            // Dismiss for in-call status bar changes but not rotation
            if !rotating {
                dismissMenu()
            }
        case UIApplication.didEnterBackgroundNotification:
            if dismissWhenBackgrounded {
                dismissMenu()
            }
        default: break
        }
    }

    @discardableResult func addDismissPanGesture(to view: UIView) -> UIPanGestureRecognizer {
        return UIPanGestureRecognizer {
            $0.cancelsTouchesInView = false
            $0.addTarget(self, action: #selector(handleDismissMenuPan(_:)))
            view.addGestureRecognizer($0)
        }
    }

    @objc func handleDismissMenuTap(_ tap: UITapGestureRecognizer) {
        guard view.window?.hitTest(tap.location(in: nil), with: nil) == view.superview else { return }
        dismissMenu()
    }

    @objc func handleDismissMenuPan(_ gesture: UIPanGestureRecognizer) {
        handleMenuPan(gesture, false)
    }

    func factor(_ presenting: Bool) -> CGFloat {
        return presenting ? presentFactor : hideFactor
    }

    var presentFactor: CGFloat {
        return leftSide ? 1 : -1
    }

    var hideFactor: CGFloat {
        return -presentFactor
    }
}
