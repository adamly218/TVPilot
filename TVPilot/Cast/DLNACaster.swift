import Foundation

/// Plays a URL on the TV through its built-in UPnP/DLNA media renderer.
enum DLNACaster {
    static func contentFeatures(isImage: Bool) -> String {
        isImage
            ? "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=00900000000000000000000000000000"
            : "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
    }

    static func play(_ media: URL, mime: String, title: String, on host: String) async throws {
        let control = try await avTransportURL(host: host)
        let isImage = mime.hasPrefix("image/")
        let upnpClass = isImage ? "object.item.imageItem.photo" : (mime.hasPrefix("audio/") ? "object.item.audioItem.musicTrack" : "object.item.videoItem")
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="0" parentID="-1" restricted="1"><dc:title>\(escape(title))</dc:title><upnp:class>\(upnpClass)</upnp:class>\
        <res protocolInfo="http-get:*:\(mime):\(contentFeatures(isImage: isImage))">\(escape(media.absoluteString))</res></item></DIDL-Lite>
        """
        try? await soap(control, action: "Stop", body: "<InstanceID>0</InstanceID>")
        try await soap(control, action: "SetAVTransportURI", body:
            "<InstanceID>0</InstanceID><CurrentURI>\(escape(media.absoluteString))</CurrentURI><CurrentURIMetaData>\(escape(didl))</CurrentURIMetaData>")
        try await soap(control, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    static func stop(on host: String) async {
        guard let control = try? await avTransportURL(host: host) else { return }
        try? await soap(control, action: "Stop", body: "<InstanceID>0</InstanceID>")
    }

    /// Reads the TV's device description to find the AVTransport control URL.
    private static func avTransportURL(host: String) async throws -> URL {
        for (port, path) in [(9197, "/dmr")] {
            guard let url = URL(string: "http://\(host):\(port)\(path)"),
                  let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3)) else { continue }
            let parser = ServiceParser()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            xml.parse()
            if let controlPath = parser.avTransportControl {
                let absolute = controlPath.hasPrefix("/") ? controlPath : "/" + controlPath
                if let control = URL(string: "http://\(host):\(port)\(absolute)") { return control }
            }
        }
        throw CastError.noRenderer
    }

    private static func soap(_ url: URL, action: String, body: String) async throws {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\(body)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(decoding: data, as: UTF8.self)
            let detail = text.range(of: "<errorDescription>").flatMap { start in
                text.range(of: "</errorDescription>").map { String(text[start.upperBound..<$0.lowerBound]) }
            } ?? "(\(action) returned \(http.statusCode))"
            throw CastError.rejected(detail)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Pulls the AVTransport service's controlURL out of a UPnP device description.
private final class ServiceParser: NSObject, XMLParserDelegate {
    private(set) var avTransportControl: String?
    private var element = ""
    private var serviceType = ""
    private var controlURL = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name
        if name == "service" { serviceType = ""; controlURL = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element == "serviceType" { serviceType += string }
        if element == "controlURL" { controlURL += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "service", serviceType.contains("AVTransport"), avTransportControl == nil {
            avTransportControl = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        element = ""
    }
}
