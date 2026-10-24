import Foundation
import os

/// Binary fixtures travel as real bytes through the native reader's isolated session.
final class SkillShelfFileStubProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = OSAllocatedUnfairLock(initialState:false)
    override class func canInit(with request:URLRequest)->Bool {
        guard SkillShelfStubFixture.active, let path = request.url?.path else { return false }
        return path.contains("/api/file") || path.hasSuffix("/api/skills/files") || path.hasSuffix("/api/skills/zip")
    }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard let reply = SkillShelfStubFixture.fileResponse(request), let url = request.url else {
            client?.urlProtocol(self,didFailWithError:URLError(.resourceUnavailable)); return
        }
        let finish:@Sendable ()->Void = { [self] in
            guard !stopped.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(url:url,statusCode:reply.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":reply.type,"Content-Length":"\(reply.data.count)"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:reply.data); client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline:.now() + reply.delay,execute:finish) } else { finish() }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}
