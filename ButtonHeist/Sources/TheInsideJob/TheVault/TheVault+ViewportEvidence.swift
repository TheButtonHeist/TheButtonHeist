#if canImport(UIKit)
#if DEBUG
import UIKit

import TheScore

extension TheVault {

    // MARK: - Viewport Evidence

    /// End stored geometry's lifetime when its live owner leaves or changes at the capture boundary.
    func invalidatedGeometryOwners(in observation: InterfaceObservation) -> Set<TreePath> {
        Set(currentLiveCapture.dispatchReferences.scrollableContainerViewsByPath.compactMap { path, previous in
            guard let previousView = previous.view,
                  observation.liveCapture.scrollView(forContainerPath: path) === previousView
            else { return path }
            return nil
        })
    }

    /// Confirm missing remembered entries only where this capture read their stored positions.
    func confirmedMissingElements(in observation: InterfaceObservation) -> Set<HeistId> {
        let freshIDs = observation.tree.elementIDs
        var rememberedByOwner: [TreePath: [InterfaceTree.Element]] = [:]
        for element in interfaceTree.elements.values where !freshIDs.contains(element.heistId) {
            guard let ownerPath = element.scrollContainerPath,
                  case .available(let geometry) = element.geometry.view,
                  geometry.ownerPath == ownerPath
            else { continue }
            rememberedByOwner[ownerPath, default: []].append(element)
        }

        let capturedContainers = observation.tree.orderedContainers
        var missing = Set<HeistId>()
        for (ownerPath, elements) in rememberedByOwner {
            guard let owner = interfaceTree.containers[ownerPath],
                  let previousView = currentLiveCapture.scrollView(forContainerPath: ownerPath)
            else { continue }
            let matches = capturedContainers.filter {
                Self.matchesContainer($0, to: owner)
                    && observation.liveCapture.scrollView(forContainerPath: $0.path) === previousView
            }
            guard matches.count == 1,
                  let scrollView = observation.liveCapture.scrollView(forContainerPath: matches[0].path),
                  let viewport = Self.capturedViewport(in: scrollView)
            else { continue }
            for element in elements {
                guard case .available(let geometry) = element.geometry.view,
                      !geometry.frame.cgRect.isEmpty,
                      viewport.contains(geometry.frame.cgRect)
                else { continue }
                missing.insert(element.heistId)
            }
        }
        return missing
    }

    private static func capturedViewport(in scrollView: UIScrollView) -> CGRect? {
        guard scrollView.window != nil,
              !scrollView.bhIsUnsafeForProgrammaticScrolling,
              !Navigation.isObscuredByPresentation(view: scrollView)
        else { return nil }
        var viewport = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        var ancestor: UIView? = scrollView
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            if view.clipsToBounds || view is UIWindow {
                viewport = viewport.intersection(scrollView.convert(view.bounds, from: view))
            }
            ancestor = view.superview
        }
        return viewport.isNull || viewport.isEmpty ? nil : viewport
    }
}

#endif // DEBUG
#endif // canImport(UIKit)
