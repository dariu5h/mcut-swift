#if canImport(ModelIO)
import MCUT
import ModelIO
import simd

// MARK: - MDLMesh data extraction (caller-provided, tested)

/// getting basic data of MDLMesh
extension MDLMesh {

    private func getVectors(withAttributeNamed named: String) -> Array<SIMD3<Float>> {
        var result: Array<SIMD3<Float>> = []

        guard let vertexData = vertexAttributeData(forAttributeNamed: named) else {
            return result
        }

        let format = vertexData.format
        let stride = vertexData.stride
        let bufferPointer = vertexData.dataStart
        let elementCount = vertexCount

        var vertices: Array<SIMD3<Float>> = .init(repeating: .zero, count: vertexCount)

        switch format {
            case .float3: // For `float3` format

                for i in 0 ..< elementCount {
                    let ptr = bufferPointer.advanced(by: i * stride)
                    let value = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    vertices[i] = value
                }

                result = vertices

            case .float4: // For `float4` format

                for i in 0 ..< elementCount {
                    let ptr = bufferPointer.advanced(by: i * stride)
                    let value = ptr.assumingMemoryBound(to: SIMD4<Float>.self).pointee
                    vertices[i] = value.xyz
                }

                result = vertices

            default:
                break
        }

        return result
    }

    func getPositions() -> Array<SIMD3<Float>> {
        getVectors(withAttributeNamed: MDLVertexAttributePosition)
    }

    func getNormals() -> Array<SIMD3<Float>> {
        getVectors(withAttributeNamed: MDLVertexAttributeNormal)
    }

    /// Return indices in zero based
    /// - Returns: Return zero based index of 3 per face
    /// - Warning: This Function is not supported for non-triangle geometry types.
    func getIndices() -> Array<Array<Int>> {
        var indices: Array<Array<Int>> = []

        guard let subMeshsList = submeshes as? Array<MDLSubmesh> else {
            return indices
        }

        for submesh in subMeshsList {
            if submesh.geometryType != .triangles && submesh.geometryType != .triangleStrips {
                fatalError("This Function is not supported for non-triangle geometry types.")
            }

            let indexBuffer = submesh.indexBuffer
            let indexBufferMap = indexBuffer.map()
            let indexPointer = indexBufferMap.bytes // UnsafeMutableRawPointer to the index data

            // Get the total number of indices and their type
            let indexCount = submesh.indexCount
            let indexType = submesh.indexType

            var rawIndices: Array<Int> = []

            // Extract indices based on their type
            switch indexType {
                case .uInt16: // 16-bit unsigned integers
                    let indices = indexPointer.bindMemory(to: UInt16.self, capacity: indexCount)
                    var indexArray: Array<UInt16> = []
                    for i in 0 ..< indexCount {
                        indexArray.append(indices[i])
                    }

                    rawIndices = indexArray.map { Int($0) }

                case .uInt32: // 32-bit unsigned integers
                    let indices = indexPointer.bindMemory(to: UInt32.self, capacity: indexCount)
                    var indexArray: Array<UInt32> = []
                    for i in 0 ..< indexCount {
                        indexArray.append(indices[i])
                    }

                    rawIndices = indexArray.map { Int($0) }

                default:
                    break
            }

            switch submesh.geometryType {
                case .triangles:
                    for i in stride(from: 0, to: rawIndices.count, by: 3) {
                        indices.append([rawIndices[i], rawIndices[i + 1], rawIndices[i + 2]])
                    }

                case .triangleStrips:
                    indices.append([rawIndices[0], rawIndices[1], rawIndices[2]])

                    for i in stride(from: 1, to: rawIndices.count, by: 1) {
                        indices.append([rawIndices[i], rawIndices[i + 1], rawIndices[i + 2]])
                    }

                default:
                    break
            }
        }

        return indices
    }
}

/// `value.xyz` used by `getVectors` above — drop the w component of a float4.
private extension SIMD4 {
    var xyz: SIMD3<Scalar> { SIMD3(x, y, z) }
}

// MARK: - MDLMesh ⇄ MCUTMesh

extension MCUTMesh {
    /// Build an `MCUTMesh` from an `MDLMesh` (positions + triangle submeshes).
    ///
    /// - Parameter weldTolerance: coincident vertices are merged at this tolerance before returning
    ///   (see ``MCUTMesh/welded(tolerance:)``). SDK meshes split vertices per face, so welding is on
    ///   by default; pass `nil` to keep the mesh exactly as authored.
    public init(_ mesh: MDLMesh, weldTolerance: Float? = 1e-5) {
        let positions = mesh.getPositions()
        let triangles = mesh.getIndices()

        var faceIndices = [UInt32]()
        faceIndices.reserveCapacity(triangles.count * 3)
        for tri in triangles {
            for idx in tri { faceIndices.append(UInt32(idx)) }
        }

        let raw = MCUTMesh(vertices: positions, indices: faceIndices)
        self = weldTolerance.map { raw.welded(tolerance: $0) } ?? raw
    }

    /// Produce an `MDLMesh` (single triangulated submesh, positions only — normals/UVs are dropped).
    /// `allocator` supplies the backing buffers, e.g. `MTKMeshBufferAllocator(device:)` or
    /// `MDLMeshBufferDataAllocator()`.
    public func makeMDLMesh(allocator: MDLMeshBufferAllocator) -> MDLMesh {
        // Prefer mcut's constrained-Delaunay triangulation (correct for non-convex faces); fall back
        // to a fan only for meshes that carry none (e.g. caller-built non-triangle meshes).
        let tris = triangleIndices ?? fanTriangleIndices()

        let vertexData = positions.withUnsafeBytes { Data($0) }
        let indexData = tris.withUnsafeBytes { Data($0) }

        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: tris.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil)

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        // SIMD3<Float> is 16-byte aligned/strided; .float3 reads the first 12 bytes per stride.
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        return MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: positions.count,
            descriptor: descriptor,
            submeshes: [submesh])
    }
}

// MARK: - Same-type convenience ops

/// Boolean / cut / slice that take and return `MDLMesh`, so callers stay in Model I/O types.
/// Each is sugar over `MCUTMesh(self)` → core op → `makeMDLMesh`. Inputs are welded on conversion.
/// `allocator` backs the result buffers.
extension MDLMesh {
    public func union(_ other: MDLMesh, allocator: MDLMeshBufferAllocator) throws -> MDLMesh {
        try MCUTContext().union(MCUTMesh(self), MCUTMesh(other)).makeMDLMesh(allocator: allocator)
    }

    public func intersect(_ other: MDLMesh, allocator: MDLMeshBufferAllocator) throws -> MDLMesh {
        try MCUTContext().intersect(MCUTMesh(self), MCUTMesh(other)).makeMDLMesh(allocator: allocator)
    }

    /// `self − other`.
    public func subtract(_ other: MDLMesh, allocator: MDLMeshBufferAllocator) throws -> MDLMesh {
        try MCUTContext().subtract(MCUTMesh(other), from: MCUTMesh(self)).makeMDLMesh(allocator: allocator)
    }

    /// Sever `self` along its intersection with `cutMesh`; returns the resulting fragments.
    public func cut(with cutMesh: MDLMesh, allocator: MDLMeshBufferAllocator,
                    options: CutOptions = CutOptions()) throws -> [MDLMesh] {
        var options = options
        options.triangulate = true     // need mcut's CDT to emit triangles for Model I/O
        let result = try MCUTContext().cut(MCUTMesh(self), with: MCUTMesh(cutMesh), options: options)
        return result.fragments.map { $0.mesh.makeMDLMesh(allocator: allocator) }
    }

    /// Cross-section by the plane `normal · x = offset`; returns the two welded halves.
    public func slice(byPlane normal: SIMD3<Float>, offset: Float,
                      allocator: MDLMeshBufferAllocator) throws -> (above: MDLMesh, below: MDLMesh) {
        let halves = try MCUTContext().slice(MCUTMesh(self), byPlane: normal, offset: offset)
        return (halves.above.makeMDLMesh(allocator: allocator),
                halves.below.makeMDLMesh(allocator: allocator))
    }
}
#endif
