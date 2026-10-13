import Foundation

/// Action-sized reversible changes. Large immutable geometry is retained only
/// for objects that changed, rather than every growing page array in history.
struct AnnotationChange: Codable {
    struct Positioned: Codable { var index:Int; var stroke:InkStroke }
    struct PageEdit: Codable {
        var page:Int
        var before:[Positioned]
        var after:[Positioned]
    }
    var pages:[PageEdit]
    var beforeMetadata:AnnotationStore?
    var afterMetadata:AnnotationStore?
    struct AssetEdit:Codable {var key:String;var before:Data?;var after:Data?}
    var assets:[AssetEdit]
    var beforeAssetsPresent:Bool
    var afterAssetsPresent:Bool
    static func metadata(_ value:AnnotationStore) -> AnnotationStore {
        var result=value;result.ink=[];result.imageAssets=nil;return result
    }
    init(from before:AnnotationStore,to after:AnnotationStore) {
        pages=[]
        for page in before.ink.indices where before.ink[page] != after.ink[page] {
            let old=before.ink[page],new=after.ink[page]
            let oldIDs=old.map(\.id),newIDs=new.map(\.id)
            var affected=Set<UUID>()
            for change in newIDs.difference(from:oldIDs) {
                switch change {case .insert(_,let id,_),.remove(_,let id,_):affected.insert(id)}
            }
            let previous=Dictionary(uniqueKeysWithValues:old.map{($0.id,$0)})
            for stroke in new where previous[stroke.id] != stroke {affected.insert(stroke.id)}
            pages.append(PageEdit(page:page,before:old.enumerated().compactMap{affected.contains($0.element.id) ? Positioned(index:$0.offset,stroke:$0.element):nil},after:new.enumerated().compactMap{affected.contains($0.element.id) ? Positioned(index:$0.offset,stroke:$0.element):nil}))
        }
        let a=Self.metadata(before),b=Self.metadata(after)
        beforeMetadata=a==b ? nil:a;afterMetadata=a==b ? nil:b
        beforeAssetsPresent=before.imageAssets != nil;afterAssetsPresent=after.imageAssets != nil
        assets=[]
        if before.imageAssets != after.imageAssets {
            let old=before.imageAssets ?? [:],new=after.imageAssets ?? [:]
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] {assets.append(AssetEdit(key:key,before:old[key],after:new[key]))}
        }
    }
    func applying(to model:AnnotationStore,forward:Bool) -> AnnotationStore {
        var result=model
        if let metadata=forward ? afterMetadata:beforeMetadata {
            let ink=result.ink,sources=result.imageAssets;result=metadata;result.ink=ink;result.imageAssets=sources
        }
        if forward ? afterAssetsPresent:beforeAssetsPresent {
            if result.imageAssets==nil {result.imageAssets=[:]}
            for edit in assets {result.imageAssets?[edit.key]=forward ? edit.after:edit.before}
        } else {result.imageAssets=nil}
        for edit in pages {
            let ids=Set((edit.before+edit.after).map{$0.stroke.id})
            result.ink[edit.page].removeAll{ids.contains($0.id)}
            for entry in (forward ? edit.after:edit.before).sorted(by:{$0.index<$1.index}) {
                result.ink[edit.page].insert(entry.stroke,at:min(entry.index,result.ink[edit.page].count))
            }
        }
        return result
    }
    /// Encoding recovery needs only the forward side, never duplicate old ink.
    var forwardOnly:AnnotationForwardChange {AnnotationForwardChange(self)}
    var estimatedBytes:Int {
        var total = 512 // Action/array bookkeeping also costs memory for empty notes.
        let pointBytes = MemoryLayout<InkPoint>.stride
        for page in pages {
            for entry in page.before + page.after {
                total += 256 + entry.stroke.points.count * pointBytes
                for outline in entry.stroke.outlines ?? [] {
                    total += outline.count * pointBytes
                }
            }
        }
        if let metadata = beforeMetadata { total += Self.metadataBytes(metadata) }
        if let metadata = afterMetadata { total += Self.metadataBytes(metadata) }
        for asset in assets {
            total += asset.before?.count ?? 0
            total += asset.after?.count ?? 0
        }
        return total
    }
    private static func metadataBytes(_ model: AnnotationStore) -> Int {
        func anchorBytes(_ anchor: PageAnchor) -> Int {
            256 + anchor.quote.utf8.count + anchor.prefix.utf8.count + anchor.suffix.utf8.count
        }
        // Deliberately count shared values on both sides: a conservative budget,
        // not a claim to measure Swift allocator residency exactly.
        var total = 512 + model.pages.count * 256
        for page in model.pages {
            total += page.textHash.utf8.count
            total += page.textInventoryHash?.utf8.count ?? 0
            total += page.contentHash?.utf8.count ?? 0
        }
        for mark in model.marks {
            total += 256 + anchorBytes(mark.anchor)
            total += mark.quads.count * MemoryLayout<InkPoint>.stride
            total += mark.contents.utf8.count + mark.userName.utf8.count
        }
        for note in model.notes {
            total += 256 + note.markdown.utf8.count + note.links.count * 32
            for anchor in note.anchors { total += anchorBytes(anchor) }
            for (key, value) in note.macros { total += 64 + key.utf8.count + value.utf8.count }
        }
        for image in model.images { total += 256 + image.asset.utf8.count }
        for group in model.groups { total += 64 + group.members.count * 16 }
        total += (model.objectOrder?.count ?? 0) * 16
        return total
    }

}

/// A recovery transaction stores removed identities, not the removed geometry.
struct AnnotationForwardChange:Codable {
    struct PageEdit:Codable {var page:Int;var remove:[UUID];var after:[AnnotationChange.Positioned]}
    var pages:[PageEdit]
    var metadata:AnnotationStore?
    init(_ change:AnnotationChange) {
        pages=change.pages.map{PageEdit(page:$0.page,remove:Array(Set(($0.before+$0.after).map{$0.stroke.id})),after:$0.after)}
        metadata=change.afterMetadata
    }
    func applying(to model:AnnotationStore)->AnnotationStore {
        var result=metadata ?? model
        if metadata != nil {result.ink=model.ink}
        for edit in pages {
            let removed=Set(edit.remove);result.ink[edit.page].removeAll{removed.contains($0.id)}
            for value in edit.after.sorted(by:{$0.index<$1.index}) {result.ink[edit.page].insert(value.stroke,at:min(value.index,result.ink[edit.page].count))}
        }
        return result
    }
}
