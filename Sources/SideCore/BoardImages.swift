import Foundation
import AppKit
import ImageIO
import CryptoKit

public struct BoardImage:Codable,Equatable,Sendable {
    public var id:String
    public var title:String
    public var credit:String
    public var sourceURL:String
    public var width:Int
    public var height:Int
}

public enum BoardImages {
    static var directory:URL{FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("dev.side.notch/images")}
    static func file(_ id:String,_ ext:String)->URL?{
        guard id.range(of:"^image-[a-f0-9]{24}$",options:.regularExpression) != nil else{return nil}
        return directory.appendingPathComponent(id+"."+ext)
    }
    public static func metadata(_ id:String)->BoardImage?{guard let url=file(id,"json"),let data=try? Data(contentsOf:url) else{return nil};return try? JSONDecoder().decode(BoardImage.self,from:data)}
    public static func data(_ id:String)->Data?{file(id,"png").flatMap{try? Data(contentsOf:$0)}}
    public static func store(_ data:Data,title:String,credit:String,sourceURL:String) throws ->BoardImage{
        guard data.count<=12_000_000,let source=CGImageSourceCreateWithData(data as CFData,nil),
              let p=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=p[kCGImagePropertyPixelWidth] as? Int,let h=p[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=16000,h<=16000,
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1200,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
        else{throw SideAPIError("The image could not be decoded safely.")}
        let bitmap=NSBitmapImageRep(cgImage:image)
        guard let png=bitmap.representation(using:.png,properties:[:]) else{throw SideAPIError("The reference image could not be prepared.")}
        let digest=SHA256.hash(data:Data(sourceURL.utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()
        let result=BoardImage(id:"image-"+digest,title:String(title.prefix(240)),credit:String(credit.prefix(180)),sourceURL:sourceURL,width:image.width,height:image.height)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try png.write(to:file(result.id,"png")!,options:.atomic)
        try JSONEncoder().encode(result).write(to:file(result.id,"json")!,options:.atomic)
        return result
    }
    static func allowed(_ url:URL)->Bool{
        guard url.scheme == "https",let host=url.host else{return false}
        return host == "nasa.gov" || host.hasSuffix(".nasa.gov") || host == "commons.wikimedia.org" || host == "upload.wikimedia.org" || host == "thumb.wikimedia.org"
    }
    static func fetch(_ url:URL) async throws ->Data{
        guard allowed(url) else{throw SideAPIError("Unsupported reference image source.")}
        var request=URLRequest(url:url);request.timeoutInterval=25;request.setValue("Side/0.1 (educational macOS drawing app)",forHTTPHeaderField:"User-Agent")
        let (data,response)=try await URLSession.shared.data(for:request);try Task.checkCancellation()
        guard let http=response as? HTTPURLResponse,http.statusCode==200,let final=response.url,allowed(final),data.count<=12_000_000 else{throw SideAPIError("The image library could not return this reference.")}
        return data
    }
    public static func search(query:String,source:String="auto") async throws ->[BoardImage]{
        let query=String(query.trimmingCharacters(in:.whitespacesAndNewlines).prefix(180))
        guard !query.isEmpty else{throw SideAPIError("Image search needs a subject.")}
        let space=query.range(of:"astronaut|space|moon|mars|planet|rocket|orbit|nasa|galaxy|nebula|satellite",options:[.regularExpression,.caseInsensitive]) != nil
        if source == "nasa" || (source == "auto" && space){
            let images=try await nasa(query);if !images.isEmpty || source == "nasa"{return images}
        }
        return try await commons(query)
    }
    static func nasa(_ query:String) async throws ->[BoardImage]{
        var url=URLComponents(string:"https://images-api.nasa.gov/search")!
        url.queryItems=[URLQueryItem(name:"q",value:query),URLQueryItem(name:"media_type",value:"image"),URLQueryItem(name:"page_size",value:"24")]
        if query.range(of:"spacewalk|extravehicular",options:[.regularExpression,.caseInsensitive]) != nil{url.queryItems?.append(URLQueryItem(name:"title",value:"spacewalk"))}
        let root=try JSONSerialization.jsonObject(with:await fetch(url.url!)) as? [String:Any]
        let raw=(root?["collection"] as? [String:Any])?["items"] as? [[String:Any]] ?? []
        let words=query.lowercased().split(separator:" ").map(String.init).filter{$0.count>2}
        func score(_ item:[String:Any])->Int{
            let meta=(item["data"] as? [[String:Any]])?.first ?? [:],title=(meta["title"] as? String ?? "").lowercased(),description=(meta["description"] as? String ?? "").lowercased()
            let relevance=words.reduce(0){$0+(title.contains($1) ? 8:0)+(description.contains($1) ? 2:0)}
            let event=title.range(of:"museum|conference|press|portrait|training|ceremony",options:.regularExpression) != nil
            return relevance-(event ? 25:0)
        }
        let items=raw.sorted{score($0)>score($1)}
        var found:[BoardImage]=[]
        for item in items{
            guard let meta=(item["data"] as? [[String:Any]])?.first,let id=meta["nasa_id"] as? String,
                  let href=(item["links"] as? [[String:Any]])?.first(where:{$0["render"] as? String == "image"})?["href"] as? String,let photo=URL(string:href) else{continue}
            do{found.append(try store(await fetch(photo),title:meta["title"] as? String ?? id,credit:"NASA / "+(meta["photographer"] as? String ?? meta["center"] as? String ?? "Image and Video Library"),sourceURL:"https://images.nasa.gov/details/"+id))}catch is CancellationError{throw CancellationError()}catch{continue}
            if found.count==2{break}
        }
        return found
    }
    static func plain(_ value:String)->String{value.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression).replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&#39;",with:"'").replacingOccurrences(of:"&quot;",with:"\"")}
    static func commons(_ query:String) async throws ->[BoardImage]{
        var url=URLComponents(string:"https://commons.wikimedia.org/w/api.php")!
        let params=["action":"query","format":"json","generator":"search","gsrsearch":query+" filetype:bitmap","gsrnamespace":"6","gsrlimit":"4","prop":"imageinfo","iiprop":"url|extmetadata","iiurlwidth":"960"]
        url.queryItems=params.map{URLQueryItem(name:$0.key,value:$0.value)}
        let root=try JSONSerialization.jsonObject(with:await fetch(url.url!)) as? [String:Any]
        let pages=(root?["query"] as? [String:Any])?["pages"] as? [String:[String:Any]] ?? [:]
        var found:[BoardImage]=[]
        for page in pages.values{
            guard let info=(page["imageinfo"] as? [[String:Any]])?.first,let href=info["thumburl"] as? String ?? info["url"] as? String,let photo=URL(string:href) else{continue}
            let extra=info["extmetadata"] as? [String:[String:Any]] ?? [:]
            let artist=plain(extra["Artist"]?["value"] as? String ?? "Wikimedia Commons")
            let license=plain(extra["LicenseShortName"]?["value"] as? String ?? "See source")
            do{found.append(try store(await fetch(photo),title:page["title"] as? String ?? query,credit:artist+" · "+license,sourceURL:info["descriptionurl"] as? String ?? "https://commons.wikimedia.org"))}catch is CancellationError{throw CancellationError()}catch{continue}
            if found.count==2{break}
        }
        return found
    }
    public static func content(_ images:[BoardImage])->[[String:Any]]{
        images.flatMap{image -> [[String:Any]] in
            guard let data=data(image.id) else{return []}
            return [["type":"input_text","text":"Reference image \(image.id): \(image.title). Credit: \(image.credit). Source: \(image.sourceURL)"],["type":"input_image","image_url":"data:image/png;base64,"+data.base64EncodedString(),"detail":"high"]]
        }
    }
}
