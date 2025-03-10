//
//  VerificationSheetFlowController.swift
//  StripeIdentity
//
//  Created by Mel Ludowise on 10/29/21.
//

import UIKit
@_spi(STP) import StripeCore
@_spi(STP) import StripeCameraCore

protocol VerificationSheetFlowControllerDelegate: AnyObject {
    /// Invoked when the user has dismissed the navigation controller
    func verificationSheetFlowControllerDidDismiss(_ flowController: VerificationSheetFlowControllerProtocol)
}

protocol VerificationSheetFlowControllerProtocol: AnyObject {
    var delegate: VerificationSheetFlowControllerDelegate? { get set }

    var navigationController: UINavigationController { get }

    func transitionToNextScreen(
        apiContent: VerificationSheetAPIContent,
        sheetController: VerificationSheetControllerProtocol,
        completion: @escaping () -> Void
    )

    func replaceCurrentScreen(
        with viewController: UIViewController
    )

    var uncollectedFields: Set<VerificationPageFieldType> { get }
}

enum VerificationSheetFlowControllerError: Error, Equatable {
    case missingRequiredInput([VerificationPageFieldType])

    var localizedDescription: String {
        // TODO(mludowise|IDPROD-2816): Display a different error message since this is an unrecoverable state
        return NSError.stp_unexpectedErrorMessage()
    }
}

final class VerificationSheetFlowController {

    let merchantLogo: UIImage

    var delegate: VerificationSheetFlowControllerDelegate?

    init(merchantLogo: UIImage) {
        self.merchantLogo = merchantLogo
    }

    private(set) lazy var navigationController: UINavigationController = {
        let navigationController = IdentityFlowNavigationController(rootViewController: LoadingViewController())
        navigationController.identityDelegate = self
        return navigationController
    }()
}

@available(iOSApplicationExtension, unavailable)
extension VerificationSheetFlowController: VerificationSheetFlowControllerProtocol {
    /// Transitions to the next view controller in the flow with a 'push' animation.
    /// - Note: This may replace the navigation stack or push an additional view
    ///   controller onto the stack, depending on whether on where the user is in the flow.
    func transitionToNextScreen(
        apiContent: VerificationSheetAPIContent,
        sheetController: VerificationSheetControllerProtocol,
        completion: @escaping () -> Void
    ) {
        // Check if the user is done entering all the missing fields and we tell
        // the server they're done entering data.
        if VerificationSheetFlowController.shouldSubmit(apiContent: apiContent) {
            // Wait until we're done submitting to see if there's an error response
            sheetController.submit { [weak self, weak sheetController] updatedAPIContent in
                guard let self = self,
                      let sheetController = sheetController else {
                    return
                }
                self.transitionToNextScreenWithoutCheckingSubmit(
                    apiContent: updatedAPIContent,
                    sheetController: sheetController,
                    completion: completion
                )
            }
        } else {
            transitionToNextScreenWithoutCheckingSubmit(
                apiContent: apiContent,
                sheetController: sheetController,
                completion: completion
            )
        }
    }

    /// Transitions to the given viewController by replacing the currently displayed view controller
    func replaceCurrentScreen(
        with newViewController: UIViewController
    ) {
        var viewControllers = navigationController.viewControllers
        viewControllers.removeLast()
        viewControllers.append(newViewController)
        navigationController.setViewControllers(viewControllers, animated: true)
    }

    /// - Note: This method should not be called directly from outside of this class except for tests
    func transitionToNextScreenWithoutCheckingSubmit(
        apiContent: VerificationSheetAPIContent,
        sheetController: VerificationSheetControllerProtocol,
        completion: @escaping () -> Void
    ) {
        nextViewController(
            apiContent: apiContent,
            sheetController: sheetController
        ) { [weak self] nextViewController in
            self?.transitionToNextScreen(
                withViewController: nextViewController,
                shouldAnimate: true,
                completion: completion
            )
        }
    }

    /// - Note: This method should not be called directly from outside of this class except for tests
    func transitionToNextScreen(
        withViewController nextViewController: UIViewController,
        shouldAnimate: Bool,
        completion: @escaping () -> Void
    ) {
        // If the only view in the stack is a loading screen, they should not be
        // able to hit the back button to get back into a loading state.
        let isInitialLoadingState = navigationController.viewControllers.count == 1
            && navigationController.viewControllers.first is LoadingViewController

        // If the user is seeing the success screen, it means their session has
        // been submitted and they can't go back to edit their input.
        let isSuccessState = nextViewController is SuccessViewController

        // Don't display a back button, so replace the navigation stack
        if isInitialLoadingState || isSuccessState {
            navigationController.setViewControllers([nextViewController], animated: shouldAnimate)
        } else {
            navigationController.pushViewController(nextViewController, animated: shouldAnimate)
        }

        // Call completion block after navigation controller animation, if possible
        guard shouldAnimate,
              let coordinator = navigationController.transitionCoordinator
        else {
            DispatchQueue.main.async {
                completion()
            }
            return
        }

        coordinator.animate(alongsideTransition: nil, completion: { _ in completion() })
    }

    /// Instantiates and returns the next view controller to display in the flow.
    /// - Note: This method should not be called directly from outside of this class except for tests
    func nextViewController(
        apiContent: VerificationSheetAPIContent,
        sheetController: VerificationSheetControllerProtocol,
        completion: @escaping (UIViewController) -> Void
    ) {
        nextViewController(
            missingRequirements: apiContent.missingRequirements ?? [],
            staticContent: apiContent.staticContent,
            requiredDataErrors: apiContent.requiredDataErrors,
            isSubmitted: apiContent.submitted ?? false,
            lastError: apiContent.lastError,
            sheetController: sheetController,
            completion: completion
        )
    }

    /// - Note: This method should not be called directly from outside of this class except for tests
    func nextViewController(
        missingRequirements: Set<VerificationPageFieldType>,
        staticContent: VerificationPage?,
        requiredDataErrors: [VerificationPageDataRequirementError],
        isSubmitted: Bool,
        lastError: Error?,
        sheetController: VerificationSheetControllerProtocol,
        completion: @escaping (UIViewController) -> Void
    ) {
        if let lastError = lastError {
            return completion(ErrorViewController(
                sheetController: sheetController,
                error: .error(lastError)
            ))
        }

        if let inputError = requiredDataErrors.first {
            return completion(ErrorViewController(
                sheetController: sheetController,
                error: .inputError(inputError)
            ))
        }

        guard let staticContent = staticContent else {
            return completion(ErrorViewController(
                sheetController: sheetController,
                error: .error(NSError.stp_genericConnectionError())
            ))
        }

        if isSubmitted {
            return completion(SuccessViewController(
                successContent: staticContent.success,
                sheetController: sheetController
            ))
        } else if missingRequirements.contains(.biometricConsent) {
            return completion(makeBiometricConsentViewController(
                staticContent: staticContent,
                sheetController: sheetController
            ))
        } else if missingRequirements.contains(.idDocumentType) {
            return completion(DocumentTypeSelectViewController(
                sheetController: sheetController,
                staticContent: staticContent.documentSelect
            ))
        } else if !missingRequirements.intersection([.idDocumentFront, .idDocumentBack]).isEmpty {
            return sheetController.mlModelLoader.documentModelsFuture.observe(on: .main) { [weak self] result in
                guard let self = self else { return }
                completion(self.makeDocumentCaptureViewController(
                    documentScannerResult: result,
                    staticContent: staticContent,
                    sheetController: sheetController
                ))
            }
        }

        // TODO(mludowise|IDPROD-2816): Display a different error message and
        // log an analytic since this is an unrecoverable state that means we've
        // sent a configuration from the server that the client can't handle.
        return completion(ErrorViewController(
            sheetController: sheetController,
            error: .error(NSError.stp_genericConnectionError())
        ))
    }

    func makeBiometricConsentViewController(
        staticContent: VerificationPage,
        sheetController: VerificationSheetControllerProtocol
    ) -> UIViewController {
        do {
            return try BiometricConsentViewController(
                merchantLogo: merchantLogo,
                consentContent: staticContent.biometricConsent,
                sheetController: sheetController
            )
        } catch {
            // TODO(mludowise|IDPROD-2816): Display a different error message and
            // log an analytic since this is an unrecoverable state that means we've
            // sent a configuration from the server that the client can't handle.
            return ErrorViewController(
                sheetController: sheetController,
                error: .error(NSError.stp_genericConnectionError())
            )
        }
    }

    func makeDocumentCaptureViewController(
        documentScannerResult: Result<DocumentScannerProtocol, Error>,
        staticContent: VerificationPage,
        sheetController: VerificationSheetControllerProtocol
    ) -> UIViewController {
        // Show error if we haven't collected document type
        guard let documentType = sheetController.collectedData.idDocument?.type else {
            // TODO(mludowise|IDPROD-2816): Log an analytic since this is an
            // unrecoverable state that means we've sent a configuration
            // from the server that the client can't handle.
            return ErrorViewController(
                sheetController: sheetController,
                error: .error(VerificationSheetFlowControllerError.missingRequiredInput([.idDocumentType]))
            )
        }

        let documentUploader = DocumentUploader(
            configuration: .init(from: staticContent.documentCapture),
            apiClient: sheetController.apiClient
        )

        switch documentScannerResult {
        case .failure:
            // TODO(mludowise|IDPROD-2816): Log an analytic since this means the
            // ML models cannot be loaded.

            // Return document upload screen if we can't load models for auto-capture
            return DocumentFileUploadViewController(
                documentType: documentType,
                requireLiveCapture: staticContent.documentCapture.requireLiveCapture,
                sheetController: sheetController,
                documentUploader: documentUploader
            )

        case .success(let documentScanner):
            return DocumentCaptureViewController(
                apiConfig: staticContent.documentCapture,
                documentType: documentType,
                sheetController: sheetController,
                cameraSession: makeDocumentCaptureCameraSession(),
                documentUploader: documentUploader,
                documentScanner: documentScanner
            )
        }
    }

    private func makeDocumentCaptureCameraSession() -> CameraSessionProtocol {
        #if targetEnvironment(simulator)
            return MockSimulatorCameraSession(images: IdentityVerificationSheet.simulatorDocumentCameraImages)
        #else
            return CameraSession()
        #endif
    }

    /// Returns true if the user has finished filling out the required fields and the VerificationSession is ready to be submitted
    static func shouldSubmit(apiContent: VerificationSheetAPIContent) -> Bool {
        guard let missingRequirements = apiContent.missingRequirements,
              let isSubmitted = apiContent.submitted,
              apiContent.lastError == nil && apiContent.requiredDataErrors.isEmpty else {
            return false
        }
        return missingRequirements.isEmpty && !isSubmitted
    }

    // MARK: - Collected Fields

    /// Set of fields the view controllers in the navigation stack are collecting from the user
    var collectedFields: Set<VerificationPageFieldType> {
        return navigationController.viewControllers.reduce(Set<VerificationPageFieldType>()) { partialResult, vc in
            guard let dataCollectingVC = vc as? IdentityDataCollecting else {
                return partialResult
            }
            return partialResult.union(dataCollectingVC.collectedFields)
        }
    }

    /// Set of fields not collected by any of the view controllers in the navigation stack
    var uncollectedFields: Set<VerificationPageFieldType> {
        return Set(VerificationPageFieldType.allCases).subtracting(collectedFields)
    }
}

// MARK: - IdentityFlowNavigationControllerDelegate

extension VerificationSheetFlowController: IdentityFlowNavigationControllerDelegate {
    func identityFlowNavigationControllerDidDismiss(_ navigationController: IdentityFlowNavigationController) {
        delegate?.verificationSheetFlowControllerDidDismiss(self)
    }
}
