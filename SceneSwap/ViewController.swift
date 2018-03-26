//
//  ViewController.swift
//  Backdrop Demo
//
//  Created by Muhammad Rizwan on 13//18.
//  Copyright © 2018 Muhammad Rizwan. All rights reserved.
//

import UIKit
import Metal
import MetalKit
import ARKit
import AudioToolbox

extension MTKView : RenderDestinationProvider {
}

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate {
    
    
    var obj = "Game"
    var image = "GameTex"
    var session: ARSession!
    var renderer: Renderer!
     @IBOutlet weak private var mixFactorSlider: UISlider!
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let but = UIBarButtonItem(image: #imageLiteral(resourceName: "menu-button"), style: .plain , target: self, action: #selector(self.openLeft))
        self.navigationItem.leftBarButtonItem = but
       startInitials()
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap(gestureRecognize:)))
        view.addGestureRecognizer(tapGesture)
        
    }
    
    func startInitials(){
        // Set the view's delegate
        session = ARSession()
        session.delegate = self
        // Set the view to use the default device
        if let view = self.view as? MTKView {
            view.device = MTLCreateSystemDefaultDevice()
            view.backgroundColor = UIColor.clear
            view.delegate = self
            
            guard view.device != nil else {
                print("Metal is not supported on this device")
                return
            }
            
            // Configure the renderer to draw to the view
            renderer = Renderer(session: session, metalDevice: view.device!, renderDestination: view)
            renderer.image = self.image
            renderer.obj = self.obj
            renderer.drawRectResized(size: view.bounds.size)
        }
    }
    
    func change(){
        renderer.image = self.image
        renderer.obj = self.obj
        renderer = nil
        startInitials()
        let configuration = ARFaceTrackingConfiguration()
        session.run(configuration)
    }
    
    
    
    @objc func openLeft(){
     self.sideMenuController?.showLeftView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARFaceTrackingConfiguration()
//        let configuration = ARWorldTrackingConfiguration()
        // Run the view's session
        session.run(configuration)
        
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
//        session.pause()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Release any cached data, images, etc that aren't in use.
    }
    
    @objc
    func handleTap(gestureRecognize: UITapGestureRecognizer) {
        // Create anchor using the camera's current position
        if let currentFrame = session.currentFrame {
            
            // Create a transform with a translation of 0.2 meters in front of the camera
            var translation = matrix_identity_float4x4
            translation.columns.3.z = -0.2
            let transform = simd_mul(currentFrame.camera.transform, translation)
            
            // Add a new anchor to the session
            let anchor = ARAnchor(transform: transform)
            session.add(anchor: anchor)
        }
    }
    
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        renderer.update()
    }
    
    @IBAction func captureImage(_ sender: Any) {
//        AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_Vibrate))
        AudioServicesPlaySystemSound(1108)
        if let view = self.view as? MTKView {
            view.framebufferOnly = false
            let texture = view.currentDrawable!.texture
            if let imageRef = texture.toImage() {
//                let image = NSImage(CGImage: imageRef, size: NSSize(width: texture.width, height: texture.height))
                
                let img = UIImage(cgImage: imageRef, scale: CGFloat(texture.width/texture.height), orientation: UIImageOrientation.up)
                
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            }

            
        }
    }
    
   

    // MARK: - ARSessionDelegate
    
    /*func session(_ session: ARSession, didUpdate frame: ARFrame) {
        renderer.update()
    }*/
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        
    }
    
    @IBAction private func changeMixFactor(_ sender: UISlider) {
        let mixFactor = sender.value
        self.renderer.mixFactor = mixFactor
//        dataOutputQueue.async {
//            self.renderer.mixFactor = mixFactor
//        }
//        
//        processingQueue.async {
//            self.renderer.mixFactor = mixFactor
//        }
    }
}


extension MTLTexture {
    
    func bytes() -> UnsafeMutableRawPointer {
        let width = self.width
        let height   = self.height
        let rowBytes = self.width * 4
        let p = malloc(width * height * 4)
        
        self.getBytes(p!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        
        return p!
    }
    
    func toImage() -> CGImage? {
        let p = bytes()
        
        let pColorSpace = CGColorSpaceCreateDeviceRGB()
        
        let rawBitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let bitmapInfo:CGBitmapInfo = CGBitmapInfo(rawValue: rawBitmapInfo)
        
        let selftureSize = self.width * self.height * 4
        let rowBytes = self.width * 4
        //        let provider = CGDataProviderCreateWithData(nil, p, selftureSize, nil)
        let provider = CGDataProvider(dataInfo: nil, data: p, size: selftureSize) { (po, poi, value) in
            
        }
        let cgImageRef = CGImage(width: self.width, height: self.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: pColorSpace, bitmapInfo: bitmapInfo, provider: provider!, decode: nil, shouldInterpolate: true, intent: CGColorRenderingIntent.defaultIntent)!
        
        return cgImageRef
    }
}




