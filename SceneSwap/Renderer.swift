//
//  Renderer.swift
//  Backdrop Demo
//
//  Created by Muhammad Rizwan on 13//18.
//  Copyright © 2018 Muhammad Rizwan. All rights reserved.
//

import Foundation
import Metal
import MetalKit
import ARKit

protocol RenderDestinationProvider {
    var currentRenderPassDescriptor: MTLRenderPassDescriptor? { get }
    var currentDrawable: CAMetalDrawable? { get }
    var colorPixelFormat: MTLPixelFormat { get set }
    var depthStencilPixelFormat: MTLPixelFormat { get set }
    var sampleCount: Int { get set }
}

// The max number of command buffers in flight
let kMaxBuffersInFlight: Int = 3

// The max number anchors our uniform buffer will hold
let kMaxAnchorInstanceCount: Int = 64

// The 16 byte aligned size of our uniform structures
let kAlignedSharedUniformsSize: Int = (MemoryLayout<SharedUniforms>.size & ~0xFF) + 0x100
let kAlignedInstanceUniformsSize: Int = ((MemoryLayout<InstanceUniforms>.size * kMaxAnchorInstanceCount) & ~0xFF) + 0x100

// Vertex data for an image plane
let kImagePlaneVertexData: [Float] = [
    -1.0, -1.0,  0.0, 1.0,
    1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
]


class Renderer {
    
//    var obj : String!
//    var image : String!
    let session: ARSession
    let device: MTLDevice
    let inFlightSemaphore = DispatchSemaphore(value: kMaxBuffersInFlight)
    var renderDestination: RenderDestinationProvider
    var shouldRender : Bool = true
    
    // Metal objects
    var commandQueue: MTLCommandQueue!
    var sharedUniformBuffer: MTLBuffer!
    var anchorUniformBuffer: MTLBuffer!
    var imagePlaneVertexBuffer: MTLBuffer!
    var capturedImagePipelineState: MTLRenderPipelineState!
    var capturedImageDepthState: MTLDepthStencilState!
    var anchorPipelineState: MTLRenderPipelineState!
    var anchorDepthState: MTLDepthStencilState!
    var capturedImageTextureY: CVMetalTexture?
    var capturedImageTextureCbCr: CVMetalTexture?
    var capturedImageTextureDepth: CVMetalTexture?
    var anchorTexture: MTLTexture?
    var mixFactor: Float = 1.0
    struct MixerParameters {
        var mixFactor: Float
    }
    var sourceTexture: MTLTexture?
    

    
    lazy var videoImageTextureProvider: VideoImageTextureProvider? = {
        let provider = VideoImageTextureProvider(device: self.device, delegate: self)
        return provider
    }()
    
    // MARK: Image Filters
    // Lazily initialized variables for each of the supported filters
    lazy var passThrough: PassThrough = {
        return PassThrough(device: self.device)
    }()
    
    lazy var gaussianBlur: GaussianBlur = {
        return GaussianBlur(device: self.device)
    }()
    
    lazy var median: Median = {
        return Median(device: self.device)
    }()
    
    lazy var laplacian: Laplacian = {
        return Laplacian(device: self.device)
    }()
    
    lazy var sobel: Sobel = {
        return Sobel(device: self.device)
    }()
    
    lazy var thresholdBinary: ThresholdBinary = {
        return ThresholdBinary(device: self.device)
    }()
    
    lazy var convolutionEmboss: ConvolutionEmboss = {
        return ConvolutionEmboss(device: self.device)
    }()
    
    lazy var convolutionSharpen: ConvolutionSharpen = {
        return ConvolutionSharpen(device: self.device)
    }()
    
    lazy var dilateBokeh: DilateBokeh = {
        return DilateBokeh(device: self.device)
    }()
    
    lazy var morphologyClosing: MorphologyClosing = {
        return MorphologyClosing(device: self.device)
    }()
    
    lazy var histogramEqualization: HistogramEqualization = {
        return HistogramEqualization(device: self.device)
    }()
    
    lazy var histogramSpecification: HistogramSpecification = {
        return HistogramSpecification(device: self.device)
    }()
    
    
    
    // Captured image texture cache
    var capturedImageTextureCache: CVMetalTextureCache!
    
    // Metal vertex descriptor specifying how vertices will by laid out for input into our
    //   anchor geometry render pipeline and how we'll layout our Model IO verticies
    var geometryVertexDescriptor: MTLVertexDescriptor!
    
    // MetalKit mesh containing vertex data and index buffer for our anchor geometry
    var cubeMesh: MTKMesh!
    
    // Used to determine _uniformBufferStride each frame.
    //   This is the current frame number modulo kMaxBuffersInFlight
    var uniformBufferIndex: Int = 0
    
    // Offset within _sharedUniformBuffer to set for the current frame
    var sharedUniformBufferOffset: Int = 0
    
    // Offset within _anchorUniformBuffer to set for the current frame
    var anchorUniformBufferOffset: Int = 0
    
    // Addresses to write shared uniforms to each frame
    var sharedUniformBufferAddress: UnsafeMutableRawPointer!
    
    // Addresses to write anchor uniforms to each frame
    var anchorUniformBufferAddress: UnsafeMutableRawPointer!
    
    // The number of anchor instances to render
    var anchorInstanceCount: Int = 0
    
    // The current viewport size
    var viewportSize: CGSize = CGSize()
    
    // Flag for viewport size changes
    var viewportSizeDidChange: Bool = false
    
    
    init(session: ARSession, metalDevice device: MTLDevice, renderDestination: RenderDestinationProvider,image:String, object:String) {
        self.session = session
        self.device = device
        self.renderDestination = renderDestination
        loadMetal()
        loadAssets(image: image, object: object)
        
    }
    
    func drawRectResized(size: CGSize) {
        videoImageTextureProvider?.startRunning()
        viewportSize = size
        viewportSizeDidChange = true
    }
    
    func update() {
        // Wait to ensure only kMaxBuffersInFlight are getting proccessed by any stage in the Metal
        //   pipeline (App, Metal, Drivers, GPU, etc)
        let _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
        
        // Create a new command buffer for each renderpass to the current drawable
        if let commandBuffer = commandQueue.makeCommandBuffer() {
            commandBuffer.label = "MyCommand"
            
            // Add completion hander which signal _inFlightSemaphore when Metal and the GPU has fully
            //   finished proccssing the commands we're encoding this frame.  This indicates when the
            //   dynamic buffers, that we're writing to this frame, will no longer be needed by Metal
            //   and the GPU.
            // Retain our CVMetalTextures for the duration of the rendering cycle. The MTLTextures
            //   we use from the CVMetalTextures are not valid unless their parent CVMetalTextures
            //   are retained. Since we may release our CVMetalTexture ivars during the rendering
            //   cycle, we must retain them separately here.
            var textures = [capturedImageTextureY, capturedImageTextureCbCr, capturedImageTextureDepth]
            commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
                if let strongSelf = self {
                    strongSelf.inFlightSemaphore.signal()
                }
                textures.removeAll()
            }
            
            updateBufferStates()
            let shouldUpdate = updateGameState()
            if !shouldUpdate {
                return
            }
            
            if let renderPassDescriptor = renderDestination.currentRenderPassDescriptor, let currentDrawable = renderDestination.currentDrawable, let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderEncoder.label = "MyRenderEncoder"
                var parameters = MixerParameters(mixFactor: mixFactor)
                

                renderEncoder.setFragmentBytes( UnsafeMutableRawPointer(&parameters), length: MemoryLayout<MixerParameters>.size, index: 0)
                drawAnchorGeometry(renderEncoder: renderEncoder)
                drawCapturedImage(renderEncoder: renderEncoder)
                
                // We're done encoding commands
                renderEncoder.endEncoding()
                
                let supportedImageFilter = SupportedImageFilter.Median
                let imageFilter: CommandBufferEncodable
                switch supportedImageFilter {
                case .PassThrough:              imageFilter = passThrough
                case .GaussianBlur:             imageFilter = gaussianBlur
                case .Median:                   imageFilter = median
                case .Laplacian:                imageFilter = laplacian
                case .Sobel:                    imageFilter = sobel
                case .ThresholdBinary:          imageFilter = thresholdBinary
                case .ConvolutionEmboss:        imageFilter = convolutionEmboss
                case .ConvolutionSharpen:       imageFilter = convolutionSharpen
                case .DilateBokeh:              imageFilter = dilateBokeh
                case .MorphologyClosing:        imageFilter = morphologyClosing
                case .HistogramEqualization:    imageFilter = histogramEqualization
                case .HistogramSpecification:   imageFilter = histogramSpecification
                }
                
                /** Obtain the current drawable.
                 The final destination texture is always the filtered output image written to the MTKView's drawable.
                 */
                let destinationTexture = currentDrawable.texture
                
                // Encode the image filter operation.
                imageFilter.encode(to: commandBuffer,
                                   sourceTexture: session.currentFrame?.camera as! MTLTexture,
                                   destinationTexture: destinationTexture)
                
                
                // Schedule a present once the framebuffer is complete using the current drawable
                commandBuffer.present(currentDrawable)
            }
            
            // Finalize rendering here & push the command buffer to the GPU
            commandBuffer.commit()
        }
    }
    
    // MARK: - Private
    
    func loadMetal() {
        // Create and load our basic Metal state objects
        
        // Set the default formats needed to render
        renderDestination.depthStencilPixelFormat = .depth32Float_stencil8
        renderDestination.colorPixelFormat = .bgra8Unorm
        renderDestination.sampleCount = 1
        
        // Calculate our uniform buffer sizes. We allocate kMaxBuffersInFlight instances for uniform
        //   storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        //   buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        //   to another. Anchor uniforms should be specified with a max instance count for instancing.
        //   Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        //   argument in the constant address space of our shading functions.
        let sharedUniformBufferSize = kAlignedSharedUniformsSize * kMaxBuffersInFlight
        let anchorUniformBufferSize = kAlignedInstanceUniformsSize * kMaxBuffersInFlight
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        //   CPU can access the buffer
        sharedUniformBuffer = device.makeBuffer(length: sharedUniformBufferSize, options: .storageModeShared)
        sharedUniformBuffer.label = "SharedUniformBuffer"
        
        anchorUniformBuffer = device.makeBuffer(length: anchorUniformBufferSize, options: .storageModeShared)
        anchorUniformBuffer.label = "AnchorUniformBuffer"
        
        // Create a vertex buffer with our image plane vertex data.
        let imagePlaneVertexDataCount = kImagePlaneVertexData.count * MemoryLayout<Float>.size
        imagePlaneVertexBuffer = device.makeBuffer(bytes: kImagePlaneVertexData, length: imagePlaneVertexDataCount, options: [])
        imagePlaneVertexBuffer.label = "ImagePlaneVertexBuffer"
        
        // Load all the shader files with a metal file extension in the project
        let defaultLibrary = device.makeDefaultLibrary()!
        
        let capturedImageVertexFunction = defaultLibrary.makeFunction(name: "capturedImageVertexTransform")!
        let capturedImageFragmentFunction = defaultLibrary.makeFunction(name: "capturedImageFragmentShader")!
        
        // Create a vertex descriptor for our image plane vertex buffer
        let imagePlaneVertexDescriptor = MTLVertexDescriptor()
        
        // Positions.
        imagePlaneVertexDescriptor.attributes[0].format = .float2
        imagePlaneVertexDescriptor.attributes[0].offset = 0
        imagePlaneVertexDescriptor.attributes[0].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Texture coordinates.
        imagePlaneVertexDescriptor.attributes[1].format = .float2
        imagePlaneVertexDescriptor.attributes[1].offset = 8
        imagePlaneVertexDescriptor.attributes[1].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Buffer Layout
        imagePlaneVertexDescriptor.layouts[0].stride = 16
        imagePlaneVertexDescriptor.layouts[0].stepRate = 1
        imagePlaneVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Create a pipeline state for rendering the captured image
        let capturedImagePipelineStateDescriptor = MTLRenderPipelineDescriptor()
        capturedImagePipelineStateDescriptor.label = "MyCapturedImagePipeline"
        capturedImagePipelineStateDescriptor.sampleCount = renderDestination.sampleCount
        capturedImagePipelineStateDescriptor.vertexFunction = capturedImageVertexFunction
        capturedImagePipelineStateDescriptor.fragmentFunction = capturedImageFragmentFunction
        capturedImagePipelineStateDescriptor.vertexDescriptor = imagePlaneVertexDescriptor
        capturedImagePipelineStateDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        capturedImagePipelineStateDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        capturedImagePipelineStateDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        
        do {
            try capturedImagePipelineState = device.makeRenderPipelineState(descriptor: capturedImagePipelineStateDescriptor)
        } catch let error {
            print("Failed to created captured image pipeline state, error \(error)")
        }
        
        let capturedImageDepthStateDescriptor = MTLDepthStencilDescriptor()
        capturedImageDepthStateDescriptor.depthCompareFunction = .always
        capturedImageDepthStateDescriptor.isDepthWriteEnabled = false
        capturedImageDepthState = device.makeDepthStencilState(descriptor: capturedImageDepthStateDescriptor)
        
        // Create captured image texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        capturedImageTextureCache = textureCache
        
        let anchorGeometryVertexFunction = defaultLibrary.makeFunction(name: "anchorGeometryVertexTransform")!
        let anchorGeometryFragmentFunction = defaultLibrary.makeFunction(name: "anchorGeometryFragmentLighting")!
        
        // Create a vertex descriptor for our Metal pipeline. Specifies the layout of vertices the
        //   pipeline should expect. The layout below keeps attributes used to calculate vertex shader
        //   output position separate (world position, skinning, tweening weights) separate from other
        //   attributes (texture coordinates, normals).  This generally maximizes pipeline efficiency
        geometryVertexDescriptor = MTLVertexDescriptor()
        
        // Positions.
        geometryVertexDescriptor.attributes[0].format = .float3
        geometryVertexDescriptor.attributes[0].offset = 0
        geometryVertexDescriptor.attributes[0].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // Texture coordinates.
        geometryVertexDescriptor.attributes[1].format = .float2
        geometryVertexDescriptor.attributes[1].offset = 0
        geometryVertexDescriptor.attributes[1].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        // Normals.
        geometryVertexDescriptor.attributes[2].format = .half3
        geometryVertexDescriptor.attributes[2].offset = 8
        geometryVertexDescriptor.attributes[2].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        // Position Buffer Layout
        geometryVertexDescriptor.layouts[0].stride = 12
        geometryVertexDescriptor.layouts[0].stepRate = 1
        geometryVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Generic Attribute Buffer Layout
        geometryVertexDescriptor.layouts[1].stride = 16
        geometryVertexDescriptor.layouts[1].stepRate = 1
        geometryVertexDescriptor.layouts[1].stepFunction = .perVertex
        
        // Create a reusable pipeline state for rendering anchor geometry
        let anchorPipelineStateDescriptor = MTLRenderPipelineDescriptor()
        anchorPipelineStateDescriptor.label = "MyAnchorPipeline"
        anchorPipelineStateDescriptor.sampleCount = renderDestination.sampleCount
        anchorPipelineStateDescriptor.vertexFunction = anchorGeometryVertexFunction
        anchorPipelineStateDescriptor.fragmentFunction = anchorGeometryFragmentFunction
        anchorPipelineStateDescriptor.vertexDescriptor = geometryVertexDescriptor
        anchorPipelineStateDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        anchorPipelineStateDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        anchorPipelineStateDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        
        do {
            try anchorPipelineState = device.makeRenderPipelineState(descriptor: anchorPipelineStateDescriptor)
        } catch let error {
            print("Failed to created anchor geometry pipeline state, error \(error)")
        }
        
        let anchorDepthStateDescriptor = MTLDepthStencilDescriptor()
        anchorDepthStateDescriptor.depthCompareFunction = .less
        anchorDepthStateDescriptor.isDepthWriteEnabled = true
        anchorDepthState = device.makeDepthStencilState(descriptor: anchorDepthStateDescriptor)
        
        // Create the command queue
        commandQueue = device.makeCommandQueue()
    }
    
    func loadAssets(image:String, object:String) {
        // Create and load our assets into Metal objects including meshes and textures
        
        // Load texture for the model
        var ext = "png"
        let loader = MTKTextureLoader(device: device)
        if image == "Ballroom"{
            ext = "jpg"
        }else if image == "GameTex"{
            ext = "png"
        }
        else if image == "OrbTestImage"{
            ext = "jpeg"
        }
        guard let texUrl = Bundle.main.url(forResource: image, withExtension: ext) else {
            fatalError("Failed to find model file.")
        }

        do {
            var modelTex : MTLTexture
            try modelTex = loader.newTexture(URL: texUrl, options: [.origin: MTKTextureLoader.Origin.flippedVertically, .SRGB: false])
            anchorTexture = modelTex
        } catch let error {
            print(error)
        }
        
        // Create a MetalKit mesh buffer allocator so that ModelIO will load mesh data directly into
        //   Metal buffers accessible by the GPU
        let metalAllocator = MTKMeshBufferAllocator(device: device)
        
        // Create a Model IO vertexDescriptor so that we format/layout our model IO mesh vertices to
        //   fit our Metal render pipeline's vertex descriptor layout
        let vertexDescriptor = MTKModelIOVertexDescriptorFromMetal(geometryVertexDescriptor)
        
        // Indicate how each Metal vertex descriptor attribute maps to each ModelIO attribute
        (vertexDescriptor.attributes[Int(kVertexAttributePosition.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (vertexDescriptor.attributes[Int(kVertexAttributeTexcoord.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        (vertexDescriptor.attributes[Int(kVertexAttributeNormal.rawValue)] as! MDLVertexAttribute).name   = MDLVertexAttributeNormal
        
        // Load the .OBJ file
//        guard let url = Bundle.main.url(forResource: "Game", withExtension: "obj") else {
//            fatalError("Failed to find model file.")
//        }
        guard let url = Bundle.main.url(forResource: object, withExtension: "obj") else {
            fatalError("Failed to find model file.")
        }
        
        let asset = MDLAsset(url: url, vertexDescriptor: vertexDescriptor, bufferAllocator: metalAllocator)
        guard let object = asset.object(at: 0) as? MDLMesh else {
            fatalError("Failed to get mesh from asset.")
        }
        
        // Use ModelIO to create a box mesh as our object
        //let mesh = MDLMesh(boxWithExtent: vector3(1, 1, 1), segments: vector3(1, 1, 1), inwardNormals: false, geometryType: .triangles, allocator: metalAllocator)
        let mesh = object //MDLMesh(sphereWithExtent: vector3(0.075, 0.075, 0.075), segments: vector2(10, 10), inwardNormals: false, geometryType: .triangles, allocator: metalAllocator)
        
        // Perform the format/relayout of mesh vertices by setting the new vertex descriptor in our
        //   Model IO mesh
        mesh.vertexDescriptor = vertexDescriptor
        
        // Create a MetalKit mesh (and submeshes) backed by Metal buffers
        do {
            try cubeMesh = MTKMesh(mesh: mesh, device: device)
        } catch let error {
            print("Error creating MetalKit mesh, error \(error)")
        }
    }
    
    func updateBufferStates() {
        // Update the location(s) to which we'll write to in our dynamically changing Metal buffers for
        //   the current frame (i.e. update our slot in the ring buffer used for the current frame)
        
        uniformBufferIndex = (uniformBufferIndex + 1) % kMaxBuffersInFlight
        
        sharedUniformBufferOffset = kAlignedSharedUniformsSize * uniformBufferIndex
        anchorUniformBufferOffset = kAlignedInstanceUniformsSize * uniformBufferIndex
        
        sharedUniformBufferAddress = sharedUniformBuffer.contents().advanced(by: sharedUniformBufferOffset)
        anchorUniformBufferAddress = anchorUniformBuffer.contents().advanced(by: anchorUniformBufferOffset)
    }
    
    func updateGameState() -> Bool {
        // Update any game state
        
        guard let currentFrame = session.currentFrame else {
            return false
        }
        
        updateSharedUniforms(frame: currentFrame)
        updateAnchors(frame: currentFrame)
        updateCapturedImageTextures(frame: currentFrame)
        
        if viewportSizeDidChange {
            viewportSizeDidChange = false
            
            updateImagePlane(frame: currentFrame)
        }
        
        return currentFrame.capturedDepthData != nil
    }
    
    func updateSharedUniforms(frame: ARFrame) {
        // Update the shared uniforms of the frame
        
        let uniforms = sharedUniformBufferAddress.assumingMemoryBound(to: SharedUniforms.self)
        
        uniforms.pointee.viewMatrix = frame.camera.viewMatrix(for: .portrait)
        uniforms.pointee.projectionMatrix = frame.camera.projectionMatrix(for: .portrait, viewportSize: viewportSize, zNear: 0.01, zFar: 1000)

        // Set up lighting for the scene using the ambient intensity if provided
        var ambientIntensity: Float = 1.0
        
        if let lightEstimate = frame.lightEstimate {
            ambientIntensity = Float(lightEstimate.ambientIntensity) / 1000.0
        }
        
        let ambientLightColor: vector_float3 = vector3(0.5, 0.5, 0.5)
        //uniforms.pointee.ambientLightColor = ambientLightColor * ambientIntensity
        uniforms.pointee.ambientLightColor = ambientLightColor
        
        var directionalLightDirection : vector_float3 = vector3(0.0, 0.0, -1.0)
        directionalLightDirection = simd_normalize(directionalLightDirection)
        uniforms.pointee.directionalLightDirection = directionalLightDirection
        
        let directionalLightColor: vector_float3 = vector3(0.6, 0.6, 0.6)
        //uniforms.pointee.directionalLightColor = directionalLightColor * ambientIntensity
        uniforms.pointee.directionalLightColor = directionalLightColor
        uniforms.pointee.materialShininess = 0
    }
    
    func updateAnchors(frame: ARFrame) {
        // Update the anchor uniform buffer with transforms of the current frame's anchors
        anchorInstanceCount = min(frame.anchors.count, kMaxAnchorInstanceCount)
        
        var anchorOffset: Int = 0
        if anchorInstanceCount == kMaxAnchorInstanceCount {
            anchorOffset = max(frame.anchors.count - kMaxAnchorInstanceCount, 0)
        }
        
        for index in 0..<anchorInstanceCount {
            let anchor = frame.anchors[index + anchorOffset]
            
            // Flip Z axis to convert geometry from right handed to left handed
            var coordinateSpaceTransform = matrix_identity_float4x4
            coordinateSpaceTransform.columns.2.z = -1.0
            
            // 0th index is the face. Use the z distance for the backdrop
            if index == 0 {
                
                var behindDist : Float = 0.15
                
                // Calculate the eye-depth of the anchor
                let uniforms = sharedUniformBufferAddress.assumingMemoryBound(to: SharedUniforms.self)
                let viewMatrix = frame.camera.viewMatrix(for: .portrait)
                let upwardsCam = viewMatrix[1, 2]
                let camHeight = viewMatrix[3, 1]
                let headHeight = anchor.transform[3, 1]
                if upwardsCam > 0.33 && camHeight - headHeight > 0.1 {
                    behindDist = 1.0
                }
                let modelMatrix = anchor.transform
                let modelViewMatrix = viewMatrix * modelMatrix
                uniforms.pointee.cutoffDistance = -modelViewMatrix[3, 2] + behindDist
            }
            //let modelMatrix = simd_mul(anchor.transform, coordinateSpaceTransform)
            let modelMatrix = simd_mul(matrix_identity_float4x4, coordinateSpaceTransform)
            
            let anchorUniforms = anchorUniformBufferAddress.assumingMemoryBound(to: InstanceUniforms.self).advanced(by: index)
            anchorUniforms.pointee.modelMatrix = modelMatrix
        }
    }
    
    func updateCapturedImageTextures(frame: ARFrame) {
        // Create two textures (Y and CbCr) from the provided frame's captured image
        let pixelBuffer = frame.capturedImage
        let depthData = frame.capturedDepthData
        
        if (CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
            return
        }
        
        if depthData != nil {
            let depthBuffer = depthData!.depthDataMap
            capturedImageTextureDepth = createTexture(fromPixelBuffer: depthBuffer, pixelFormat: .r32Float, planeIndex: 0)
            capturedImageTextureY = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.r8Unorm, planeIndex:0)
            capturedImageTextureCbCr = createTexture(fromPixelBuffer: pixelBuffer, pixelFormat:.rg8Unorm, planeIndex:1)
            
        }
        
        
    }
    
    func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, planeIndex: Int) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        
        var texture: CVMetalTexture? = nil
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, capturedImageTextureCache, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &texture)
        
        if status != kCVReturnSuccess {
            texture = nil
        }
        
        return texture
    }
    
    func updateImagePlane(frame: ARFrame) {
        // Update the texture coordinates of our image plane to aspect fill the viewport
        let displayToCameraTransform = frame.displayTransform(for: .portrait, viewportSize: viewportSize).inverted()

        let vertexData = imagePlaneVertexBuffer.contents().assumingMemoryBound(to: Float.self)
        for index in 0...3 {
            let textureCoordIndex = 4 * index + 2
            let textureCoord = CGPoint(x: CGFloat(kImagePlaneVertexData[textureCoordIndex]), y: CGFloat(kImagePlaneVertexData[textureCoordIndex + 1]))
            let transformedCoord = textureCoord.applying(displayToCameraTransform)
            vertexData[textureCoordIndex] = Float(transformedCoord.x)
            vertexData[textureCoordIndex + 1] = Float(transformedCoord.y)
        }
    }
    
    func drawCapturedImage(renderEncoder: MTLRenderCommandEncoder) {
        guard let textureY = capturedImageTextureY, let textureCbCr = capturedImageTextureCbCr, let textureDepth = capturedImageTextureDepth else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawCapturedImage")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.none)
        renderEncoder.setRenderPipelineState(capturedImagePipelineState)
        renderEncoder.setDepthStencilState(capturedImageDepthState)
        
        // Set mesh's vertex buffers
        renderEncoder.setVertexBuffer(imagePlaneVertexBuffer, offset: 0, index: Int(kBufferIndexMeshPositions.rawValue))
        
        // Set any textures read/sampled from our render pipeline
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureY), index: Int(kTextureIndexY.rawValue))
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureCbCr), index: Int(kTextureIndexCbCr.rawValue))
        renderEncoder.setFragmentTexture(CVMetalTextureGetTexture(textureDepth), index: Int(kTextureIndexDepth.rawValue))
        renderEncoder.setFragmentBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        
        // Draw each submesh of our mesh
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.popDebugGroup()
    }
    
    func drawAnchorGeometry(renderEncoder: MTLRenderCommandEncoder) {
        guard anchorInstanceCount > 0, let textureColor = anchorTexture else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("DrawAnchors")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.back)
        //renderEncoder.setTriangleFillMode(.lines)
        renderEncoder.setRenderPipelineState(anchorPipelineState)
        renderEncoder.setDepthStencilState(anchorDepthState)
        
        renderEncoder.setFragmentTexture(anchorTexture, index: Int(kTextureIndexColor.rawValue))
        
        // Set any buffers fed into our render pipeline
        renderEncoder.setVertexBuffer(anchorUniformBuffer, offset: anchorUniformBufferOffset, index: Int(kBufferIndexInstanceUniforms.rawValue))
        renderEncoder.setVertexBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        renderEncoder.setFragmentBuffer(sharedUniformBuffer, offset: sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
        
        // Set mesh's vertex buffers
        for bufferIndex in 0..<cubeMesh.vertexBuffers.count {
            let vertexBuffer = cubeMesh.vertexBuffers[bufferIndex]
            renderEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index:bufferIndex)
        }
        
        // Draw each submesh of our mesh
        for submesh in cubeMesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType, indexCount: submesh.indexCount, indexType: submesh.indexType, indexBuffer: submesh.indexBuffer.buffer, indexBufferOffset: submesh.indexBuffer.offset, instanceCount: anchorInstanceCount)
        }
        
        //renderEncoder.setTriangleFillMode(.fill)
        renderEncoder.popDebugGroup()
    }
    
    func pixelBuffer (forImage image:CGImage) -> CVPixelBuffer? {
    
        let frameSize = CGSize(width: image.width, height: image.height)
        
        var pixelBuffer:CVPixelBuffer? = nil
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(frameSize.width), Int(frameSize.height), kCVPixelFormatType_32BGRA , nil, &pixelBuffer)
        
        if status != kCVReturnSuccess {
            return nil
            
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags.init(rawValue: 0))
        let data = CVPixelBufferGetBaseAddress(pixelBuffer!)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        let context = CGContext(data: data, width: Int(frameSize.width), height: Int(frameSize.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!), space: rgbColorSpace, bitmapInfo: bitmapInfo.rawValue)
        
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer!, CVPixelBufferLockFlags(rawValue: 0))
        
        return pixelBuffer
        
    }
}

// MARK: AVCaptureVideoDataOutputSampleBufferDelegate
extension Renderer: VideoImageTextureProviderDelegate
{
    func videoImageTextureProvider(_: VideoImageTextureProvider, didProvideTexture texture: MTLTexture) {
        // Replace the source tetxure and call the MTKView's draw() method whenever the camera provides a new video frame.
        sourceTexture = texture
    }
}
