//
//  VidController+ARSessionDelegate.swift
//  VidFramework
//
//  Created by David Gavilan on 2019/03/07.
//  Copyright © 2019 David Gavilan. All rights reserved.
//

import ARKit

extension VidController: ARSessionDelegate {
    open func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if #available(iOS 12.0, *) {
                if let probe = anchor as? AREnvironmentProbeAnchor,
                    let plugin: ARPlugin? = Renderer.shared?.getPlugin(),
                    let shLight = plugin?.findProbe(identifier: probe.identifier)
                {
                    shLight.environmentTexture = probe.environmentTexture
                    continue
                }
            } else {
                // Fallback on earlier versions
            }
            if let plane = anchor as? ARPlaneAnchor {
                if let (primitive, instanceIndex) = scene.findPrimitiveInstance(by: plane.identifier) {
                    print("Updating plane \(plane.identifier.uuidString)")
                    var t = Transform(matrix: plane.transform)
                    t.scale = plane.extent
                    primitive.instances[instanceIndex].transform = t
                }
            }
        }
    }
    open func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let arPlanesName = "ARPlanes"
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor {
                if let primitive = scene.findPrimitive(by: arPlanesName) {
                    // @todo add instance
                } else {
                    let primitive = PlanePrimitive(instanceCount: 1)
                    primitive.name = arPlanesName
                    primitive.transform = Transform(matrix: plane.transform)
                    primitive.transform.scale = plane.extent
                    primitive.uuidInstanceMap[plane.identifier] = 0
                    scene.queue(primitive)
                }
            }
        }
    }
    open func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if let plane = anchor as? ARPlaneAnchor {
                if let (primitive, instanceIndex) = scene.findPrimitiveInstance(by: plane.identifier) {
                    // @todo remove instance
                    print("Removing \(plane)")
                }
            }
        }
    }
    open func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
    }
    open func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
    }
    open func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
    }
}