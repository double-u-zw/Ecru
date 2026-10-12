import AppKit
import PDFKit

enum ReaderTool: Int, CaseIterable {
    case select, pen, textHighlight, marker, eraser, lasso
    static let toolbarOrder: [ReaderTool] = [.select,.pen,.eraser,.textHighlight,.marker,.lasso]
    var title: String { ["选择", "笔", "文字高亮", "自由荧光笔", "橡皮", "圈选"][rawValue] }
    var symbol: String { ["cursorarrow", "pencil.tip", "textformat", "highlighter", "eraser", "lasso"][rawValue] }
}

/// Transparent input router. Page content is rendered exclusively by PDFKit-owned overlays.
final class ReaderCanvas: NSView {
    lazy var presentation = PageInkPresentation(canvas: self)
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue && (tool == .lasso || !selectedIDs.isEmpty || selectedHighlight != nil) { presentation.invalidateAll() }
        }
    }

    weak var reader: ReaderWindow?
    var pdfView: PDFView { reader!.pdfView }
    var session: DocumentSession { reader!.session }
    var tool: ReaderTool = .pen
    var colors: [ReaderTool: NSColor] = [.pen: .systemBlue, .textHighlight: NSColor.systemYellow.withAlphaComponent(0.45), .marker: NSColor.systemYellow.withAlphaComponent(0.28)]
    var widths: [ReaderTool: Double] = [.pen: 1.6, .marker: 14]
    var eraserRadius: CGFloat = 10
    private static var writingDefaults:UserDefaults {
        let suffix=EcruEnvironment.value("ECRU_DATA_DIR").map{AnnotationPDF.hash(Data($0.utf8)).prefix(16)}
        let dev=Bundle.main.object(forInfoDictionaryKey:"EcruBuildChannel") as? String == "development"
        return UserDefaults(suiteName:"local.ecru.writing."+(suffix.map(String.init) ?? (dev ? "development":"release")))!
    }
    var pressureEnabled=true
    var pressureSensitivity=0.65
    var automaticShapes=true
    var automaticPenReturn=true
    var tiltEraser=true
    var shapeFill:NSColor? = nil
    var shapeFillFollowsPen=true
    var effectiveShapeFill:NSColor? {shapeFill.map{shapeFillFollowsPen ? (colors[.pen] ?? .systemBlue).withAlphaComponent($0.alphaComponent):$0}}
    var recentColors:[NSColor]=[]
    private var dynamicEraserRadius:Double?
    var effectiveEraserRadius:Double {dynamicEraserRadius ?? eraserRadius}
    private var holdTimer:Timer?
    private var holdPoint=CGPoint.zero
    private var holdPointCount=0
    private var snappedShape:InkShape?
    private var snapAnchor=CGPoint.zero
    private var snapControl=CGPoint.zero
    private var eraserDidChange=false
    private var shapeResize=false
    private var resizeShape:InkShape?
    private var resizeOrigin=CGPoint.zero
    private var suppressShape=false
    override init(frame frameRect:NSRect) {super.init(frame:frameRect);loadWritingPreferences();registerForDraggedTypes(ImageImport.types+NSFilePromiseReceiver.readableDraggedTypes.map{NSPasteboard.PasteboardType($0)})}
    required init?(coder:NSCoder) {super.init(coder:coder);loadWritingPreferences()}
    private func loadWritingPreferences() {
        let d=Self.writingDefaults
        for t in [ReaderTool.pen,.marker,.textHighlight] {
            if let rgba=d.array(forKey:"color.\(t.rawValue)") as? [Double],rgba.count==4,rgba.allSatisfy({$0.isFinite && (0...1).contains($0)}) {colors[t]=NSColor(srgbRed:rgba[0],green:rgba[1],blue:rgba[2],alpha:rgba[3])}
            let w=d.double(forKey:"width.\(t.rawValue)");if (0.1...64).contains(w){widths[t]=w}
        }
        if let value=d.object(forKey:"pressureEnabled") as? Bool {pressureEnabled=value}
        if let value=d.object(forKey:"automaticShapes") as? Bool {automaticShapes=value}
        if let value=d.object(forKey:"automaticPenReturn") as? Bool {automaticPenReturn=value}
        if let value=d.object(forKey:"tiltEraser") as? Bool {tiltEraser=value}
        if let value=d.object(forKey:"pressureSensitivity") as? Double,(0.1...1).contains(value){pressureSensitivity=value}
        let r=d.double(forKey:"eraserRadius");if (2...32).contains(r){eraserRadius=r}
        if let a=d.array(forKey:"shapeFill") as? [Double],a.count==4,a.allSatisfy({$0.isFinite && (0...1).contains($0)}) {shapeFill=NSColor(srgbRed:a[0],green:a[1],blue:a[2],alpha:a[3])}
        shapeFillFollowsPen=(d.object(forKey:"shapeFillFollowsPen") as? Bool) ?? (shapeFill == nil)
        for a in (d.array(forKey:"recentColors") as? [[Double]] ?? []).prefix(8) where a.count==4 && a.allSatisfy({$0.isFinite && (0...1).contains($0)}) {recentColors.append(NSColor(srgbRed:a[0],green:a[1],blue:a[2],alpha:a[3]))}
    }
    func rememberWritingPreferences(color:NSColor? = nil) {
        let d=Self.writingDefaults
        func rgba(_ c:NSColor)->[Double] {let c=c.usingColorSpace(.sRGB) ?? .black;return [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent]}
        if let color {recentColors.removeAll{rgba($0)==rgba(color)};recentColors.insert(color,at:0);recentColors=Array(recentColors.prefix(8))}
        for t in [ReaderTool.pen,.marker,.textHighlight] {d.set(rgba(colors[t]!),forKey:"color.\(t.rawValue)");if let w=widths[t]{d.set(w,forKey:"width.\(t.rawValue)")}}
        d.set(pressureEnabled,forKey:"pressureEnabled");d.set(pressureSensitivity,forKey:"pressureSensitivity");d.set(automaticShapes,forKey:"automaticShapes");d.set(automaticPenReturn,forKey:"automaticPenReturn");d.set(tiltEraser,forKey:"tiltEraser");d.set(eraserRadius,forKey:"eraserRadius");d.set(shapeFill.map(rgba),forKey:"shapeFill");d.set(shapeFillFollowsPen,forKey:"shapeFillFollowsPen");d.set(recentColors.map(rgba),forKey:"recentColors")
    }
    var hasShapePreview:Bool {snappedShape != nil}
    var selectedShapes:[InkStroke] {guard let page=selectionPage else{return []};return strokes(page).filter{selectedIDs.contains($0.id) && $0.shape != nil}}
    func editSelectedShapes(width:Double? = nil,border:NSColor? = nil,fill:NSColor? = nil,removeFill:Bool=false,restore:Bool=false,fillMatchesBorder:Bool=false,continuous:Bool=false) {
        guard !gesture,!session.currentFileIsReadOnly,let page=selectionPage,!selectedShapes.isEmpty else{return}
        if !shapeStyleAction {guard session.beginInkAction(restore ? "恢复手绘":"调整图形") else{return};shapeStyleAction=true}
        let originals=selectedShapes
        let changed=originals.map {original -> InkStroke in
            var stroke=original
            if restore {let s=stroke.shape!;stroke.points=s.originalPoints;stroke.outlines=s.originalOutlines.isEmpty ? nil:s.originalOutlines;stroke.shape=nil;stroke.appearance = s.originalOutlines.isEmpty ? nil:.perfectFreehandV1;stroke.widthFactors=s.originalOutlines.isEmpty ? nil:Array(repeating:1,count:stroke.points.count)}
            else {
                if let width{stroke.width=width}
                if let c=border?.usingColorSpace(.sRGB){stroke.rgba=[c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent]}
                if removeFill{stroke.shape?.fill=nil;stroke.shape?.fillMode = InkShape.FillMode.none}
                else if let c=fill?.usingColorSpace(.sRGB),stroke.shape!.closed {stroke.shape?.fillMode = fillMatchesBorder ? .border:.custom;stroke.shape?.fill=fillMatchesBorder ? Array(stroke.rgba.prefix(3))+[c.alphaComponent]:[c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent]}
                if border != nil,stroke.shape?.effectiveFillMode == .border,let alpha=stroke.shape?.fill?.last {stroke.shape?.fill=Array(stroke.rgba.prefix(3))+[alpha]}
            };return stroke
        }
        replace(page,ids:Set(originals.map(\.id)),with:changed);if !continuous || NSApp.currentEvent?.type == .leftMouseUp {finishShapeStyleEditing()};reader?.updateParameters()
    }
    var selectedImages:[PageImage] {guard let page=selectionPage else{return []};return session.images(on:page).filter{selectedIDs.contains($0.id)}}
    var isCropping:Bool {cropOriginal != nil}
    func displayedImage(_ image:PageImage)->PageImage {cropPreview?.id==image.id ? cropPreview!:image}
    private func objectHit(_ page:PDFPage,_ point:CGPoint)->UUID? {
        let index=session.document.index(for:page)
        for id in session.annotations.orderedIDs(on:index).reversed() {
            if let image=session.images(on:page).first(where:{$0.id==id}),image.contains(point){return id}
            if let stroke=strokes(page).first(where:{$0.id==id}) {
                if let shape=stroke.shape,shape.closed,shape.path().contains(point){return id}
                if InkGeometry.erase(stroke,center:point,radius:max(3/pdfView.scaleFactor,stroke.width/2)) != [stroke] {return id}
            }
        };return nil
    }
    func selectObjects(_ ids:Set<UUID>,on page:PDFPage) {
        clearSelection();selectedIDs=session.annotations.expanded(ids);selectionPage=page;refreshSelectionOutline();reader?.updateParameters();presentation.invalidateAll()
    }
    private func refreshSelectionOutline() {
        guard let r=selectedBounds else{selectionOutline=[];return}
        selectionOutline=[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
    }
    private func beginObjectMove(_ page:PDFPage) {
        guard !session.annotationReadOnly,!session.currentFileIsReadOnly,!selectedImages.contains(where:{$0.locked}) else{gesture=false;objectResize=false;return}
        activePage=page
        originalMove=strokes(page).filter{selectedIDs.contains($0.id)};originalImages=selectedImages
        originalMarks=session.annotations.marks.filter{selectedIDs.contains($0.id)}
        originalOutline=selectionOutline;gesture=true;draggingMove=true
        _=startAction(objectResize ? "缩放对象":"移动对象")
    }
    private func applyObjectTransform(_ transform:CGAffineTransform,scale:Double,on page:PDFPage,rotation:Double=0) {
        func point(_ p:InkPoint)->InkPoint {InkPoint(p.cgPoint.applying(transform))}
        let ink=originalMove.map{source -> InkStroke in
            var s=source;s.points=s.points.map(point);s.outlines=s.outlines?.map{$0.map(point)};s.width=min(256,max(0.1,s.width*scale))
            if var shape=s.shape {shape.controls=shape.controls.map(point);shape.originalPoints=shape.originalPoints.map(point);shape.originalOutlines=shape.originalOutlines.map{$0.map(point)};s.shape=shape;s.points=shape.points};return s
        }
        let images=originalImages.map{source -> PageImage in
            var image=source;let center=CGPoint(x:image.rect.midX,y:image.rect.midY).applying(transform)
            image.rect=CGRect(x:center.x-image.rect.width*scale/2,y:center.y-image.rect.height*scale/2,width:image.rect.width*scale,height:image.rect.height*scale);image.rotation += rotation;return image
        }
        let marks=originalMarks.map{source -> PageMark in
            var mark=source;mark.anchor.bounds=mark.anchor.bounds.applying(transform);mark.quads=mark.quads.map(point);mark.textSpan=nil;mark.textEditable=false;return mark
        }
        session.replaceObjects(on:page,ids:selectedIDs,ink:ink,images:images,marks:marks);refreshSelectionOutline();presentation.invalidateAll()
    }
    func completeImageEditing() {
        finishInterruptedInput();let previous=insertionReturnTool;insertionReturnTool=nil
        clearSelection();if let previous {tool=previous;refreshToolCursor()};reader?.refresh()
    }
    private func insertionTarget()->(PDFPage,CGRect)? {
        guard let page=pdfView.currentPage else{return nil}
        let visible=pdfView.convert(pdfView.bounds,to:page).intersection(page.bounds(for:.cropBox))
        return (page,visible.isNull || visible.width<1 || visible.height<1 ? page.bounds(for:.cropBox):visible)
    }
    private var imageImporting=false
    private var imageImportGeneration=UUID()
    func disconnectImageImports(){imageImportGeneration=UUID();imageImporting=false}
    private func enqueueImageData(_ input:Data,at target:(PDFPage,CGPoint)?=nil) {
        guard !imageImporting,!gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly,let normal=insertionTarget() else{return}
        let destination=target ?? (normal.0,CGPoint(x:normal.1.midX,y:normal.1.midY))
        imageImporting=true
        let generation=imageImportGeneration
        DispatchQueue.global(qos:.userInitiated).async {[weak self] in
            let result=Result{try ImageImport.normalize(input)}
            DispatchQueue.main.async {[weak self] in
                guard let self,self.imageImportGeneration==generation else{return};self.imageImporting=false
                guard self.reader != nil else{return}
                switch result {
                case .success(let data):self.insertImageData(data,at:destination,normalized:true)
                case .failure(let error):self.reader?.showNotice(error.localizedDescription)
                }
            }
        }
    }
    func insertImageData(_ input:Data,at target:(PDFPage,CGPoint)?=nil,normalized:Bool=false) {
        guard !gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly else{reader?.showNotice("当前 PDF 只读，不能插入图片。");return}
        reader?.noteCard.commit()
        do {
            let data=try normalized ? input:ImageImport.normalize(input)
            guard let image=ImageImport.pixelSize(data),let normal=insertionTarget() else{return}
            let page=target?.0 ?? normal.0
            let visible=pdfView.convert(pdfView.bounds,to:page).intersection(page.bounds(for:.cropBox))
            let area=visible.isNull || visible.width<1 || visible.height<1 ? page.bounds(for:.cropBox):visible
            let factor=min(area.width*0.7/Double(image.width),area.height*0.7/Double(image.height))
            let size=CGSize(width:Double(image.width)*factor,height:Double(image.height)*factor)
            let center=target?.1 ?? CGPoint(x:normal.1.midX,y:normal.1.midY)
            let rect=CGRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height)
            let id=try session.insertImage(data,on:page,rect:rect)
            let previous=insertionReturnTool ?? tool
            setTool(.select);insertionReturnTool=previous;selectObjects([id],on:page)
            window?.makeFirstResponder(self);reader?.refresh()
        } catch {reader?.showNotice(error.localizedDescription)}
    }
    @objc func paste(_ sender:Any?) {pasteFromPasteboard(.general)}
    func pasteFromPasteboard(_ pasteboard:NSPasteboard) {
        if let raw=pasteboard.data(forType:ObjectClipboard.type),let packet=try? JSONDecoder().decode(ObjectClipboard.self,from:raw) {
            pasteObjects(packet);return
        }
        if let data=ImageImport.data(from:pasteboard){enqueueImageData(data)}
    }
    @objc private func pasteImageAtContext(_ sender:Any?) {if let data=ImageImport.data(from:.general){enqueueImageData(data,at:contextLocation)}}
    @objc func insertImage(_ sender:Any?) {
        guard !session.annotationReadOnly,!session.currentFileIsReadOnly else{return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.jpeg,.heic,.image];panel.allowsMultipleSelection=false
        if panel.runModal() == .OK,let url=panel.url,let data=try? Data(contentsOf:url,options:.mappedIfSafe){enqueueImageData(data)}
    }
    private static let imagePromiseQueue:OperationQueue = {let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.qualityOfService = .userInitiated;return queue}()
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        guard !gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly,(ImageImport.canRead(sender.draggingPasteboard) || sender.draggingPasteboard.canReadObject(forClasses:[NSFilePromiseReceiver.self],options:nil)) else{return []};return .copy
    }
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation {
        let p=pdfView.convert(sender.draggingLocation,from:nil)
        return pdfView.page(for:p,nearest:false) != nil ? draggingEntered(sender):[]
    }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        let view=pdfView.convert(sender.draggingLocation,from:nil)
        guard !gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly,let page=pdfView.page(for:view,nearest:false) else{return false}
        let target=(page,pdfView.convert(view,to:page))
        if let data=ImageImport.data(from:sender.draggingPasteboard){enqueueImageData(data,at:target);return true}
        guard let receivers=sender.draggingPasteboard.readObjects(forClasses:[NSFilePromiseReceiver.self],options:nil) as? [NSFilePromiseReceiver],let receiver=receivers.first else{return false}
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("EcruImageImport-"+UUID().uuidString,isDirectory:true)
        do {try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)} catch{return false}
        receiver.receivePromisedFiles(atDestination:destination,options:[:],operationQueue:Self.imagePromiseQueue){[weak self] url,error in
            let data=error == nil ? try? Data(contentsOf:url,options:.mappedIfSafe):nil
            // Only our private copy is removed; the promised original is untouched.
            let copied=data.map{Data($0)}
            try? FileManager.default.removeItem(at:destination)
            DispatchQueue.main.async {[weak self] in
                if let copied{self?.enqueueImageData(copied,at:target)}else{self?.reader?.showNotice(error?.localizedDescription ?? "拖入的文件不是可读取图片。")}
            }
        };return true
    }
    @objc func copy(_ sender:Any?) {
        guard let page=selectionPage,!selectedIDs.isEmpty else{reader?.copyText();return}
        let images=selectedImages,keys=Set(images.map(\.asset))
        let packet=ObjectClipboard(ink:strokes(page).filter{selectedIDs.contains($0.id)},images:images,marks:session.annotations.marks.filter{selectedIDs.contains($0.id)},assets:(session.annotations.imageAssets ?? [:]).filter{keys.contains($0.key)},groups:session.annotations.groups.filter{Set($0.members).isSubset(of:selectedIDs)},order:session.annotations.orderedIDs(on:session.document.index(for:page)).filter{selectedIDs.contains($0)})
        guard let data=try? JSONEncoder().encode(packet) else{return}
        NSPasteboard.general.clearContents();NSPasteboard.general.setData(data,forType:ObjectClipboard.type)
        if images.count==1,packet.ink.isEmpty,let source=packet.assets[images[0].asset] {NSPasteboard.general.setData(source,forType:.png)}
    }
    @objc func cut(_ sender:Any?) {guard !gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly else{return};copy(sender);deleteSelected()}
    private func pasteObjects(_ packet:ObjectClipboard) {
        guard !gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly,let (page,area)=insertionTarget() else{return}
        do {
            let ids=try session.pasteObjects(packet,on:page,center:CGPoint(x:area.midX,y:area.midY))
            let previous=insertionReturnTool ?? tool;setTool(.select);insertionReturnTool=previous;selectObjects(ids,on:page);reader?.refresh()
        } catch {reader?.showNotice(error.localizedDescription)}
    }
    @objc func beginCrop(_ sender:Any?) {
        guard selectedImages.count==1,selectedIDs.count==1,!selectedImages[0].locked,!session.annotationReadOnly,!session.currentFileIsReadOnly else{return}
        cropOriginal=selectedImages[0];cropPreview=cropOriginal;reader?.updateParameters();presentation.invalidateAll()
    }
    func cancelCrop(){finishInterruptedInput();cropOriginal=nil;cropPreview=nil;presentation.invalidateAll();reader?.updateParameters()}
    @objc func commitCrop(_ sender:Any?) {
        guard let image=cropPreview,let page=selectionPage,session.beginInkAction("裁剪图片") else{return}
        session.replaceObjects(on:page,ids:[image.id],ink:[],images:[image]);session.finishAction();cropOriginal=nil;cropPreview=nil;refreshSelectionOutline();presentation.invalidateAll();reader?.updateParameters()
    }
    @objc func resetCrop(_ sender:Any?) {
        guard !selectedImages.contains(where:{$0.locked}) else{return}
        editImages("重置裁剪"){image in
            var image=image
            let fullW=image.rect.width/image.crop.width,fullH=image.rect.height/image.crop.height
            let center=CGPoint(x:(0.5-image.crop.midX)*fullW,y:(0.5-image.crop.midY)*fullH).applying(image.transform)
            image.rect=CGRect(x:center.x-fullW/2,y:center.y-fullH/2,width:fullW,height:fullH);image.crop=CGRect(x:0,y:0,width:1,height:1);return image
        }
    }
    private func editImages(_ label:String,_ edit:(PageImage)->PageImage) {
        guard !gesture,!session.annotationReadOnly,!session.currentFileIsReadOnly,let page=selectionPage,!selectedImages.isEmpty,session.beginInkAction(label) else{return}
        let images=selectedImages.map(edit)
        session.replaceObjects(on:page,ids:Set(images.map(\.id)),ink:[],images:images);session.finishAction();refreshSelectionOutline();reader?.updateParameters();presentation.invalidateAll()
    }
    @objc func toggleImageLock(_ sender:Any?) {let lock = !selectedImages.allSatisfy{$0.locked};editImages(lock ? "锁定图片":"解锁图片"){var image=$0;image.locked=lock;return image}}
    @objc func rotateObjects(_ sender:Any?) {
        guard !gesture,let page=selectionPage,let r=selectedBounds,!selectedImages.contains(where:{$0.locked}) else{return}
        beginObjectMove(page);guard gesture else{return}
        let angle=Double.pi/2
        applyObjectTransform(CGAffineTransform(translationX:r.midX,y:r.midY).rotated(by:angle).translatedBy(x:-r.midX,y:-r.midY),scale:1,on:page,rotation:angle);finishInterruptedInput()
    }
    @objc func groupSelection(_ sender:Any?) {guard !session.currentFileIsReadOnly else{return};session.groupObjects(selectedIDs);reader?.updateParameters()}
    @objc func ungroupSelection(_ sender:Any?) {guard !session.currentFileIsReadOnly else{return};session.groupObjects(selectedIDs,ungroup:true);reader?.updateParameters()}
    @objc func bringToFront(_ sender:Any?) {guard !session.currentFileIsReadOnly else{return};session.arrangeObjects(selectedIDs,front:true);presentation.invalidateAll()}
    @objc func sendToBack(_ sender:Any?) {guard !session.currentFileIsReadOnly else{return};session.arrangeObjects(selectedIDs,front:false);presentation.invalidateAll()}
    @objc func objectMenu(_ sender:NSButton) {let menu=NSMenu();menu.autoenablesItems=false;addObjectCommands(to:menu);menu.popUp(positioning:nil,at:CGPoint(x:0,y:sender.bounds.maxY),in:sender)}
    private func addObjectCommands(to menu:NSMenu) {
        func item(_ title:String,_ action:Selector,_ enabled:Bool=true){let i=NSMenuItem(title:title,action:action,keyEquivalent:"");i.target=self;i.isEnabled=enabled && (action == #selector(copy(_:)) || (!session.annotationReadOnly && !session.currentFileIsReadOnly));menu.addItem(i)}
        if !selectedShapes.isEmpty {item("将当前图形样式设为默认",#selector(setShapeDefaults(_:)));item("恢复手绘",#selector(restoreSelectedShapes(_:)))}
        item("复制",#selector(copy(_:)));item("剪切",#selector(cut(_:)))
        item("旋转 90°",#selector(rotateObjects(_:)),!selectedImages.contains{$0.locked})
        if !selectedImages.isEmpty {item("裁剪（拖出保留区域）",#selector(beginCrop(_:)),selectedImages.count==1 && selectedIDs.count==1 && !selectedImages[0].locked);item("重置裁剪",#selector(resetCrop(_:)),!selectedImages.contains{$0.locked});item(selectedImages.allSatisfy{$0.locked} ? "解锁位置":"锁定位置",#selector(toggleImageLock(_:)))}
        item("移到最前",#selector(bringToFront(_:)));item("移到最后",#selector(sendToBack(_:)))
        item("组合",#selector(groupSelection(_:)),selectedIDs.count>=2);item("取消组合",#selector(ungroupSelection(_:)),session.annotations.groups.contains{!selectedIDs.isDisjoint(with:$0.members)})
    }
    @objc func finishObjects(_ sender:Any?) {completeImageEditing()}
    @objc func restoreSelectedShapes(_ sender:Any?) {editSelectedShapes(restore:true)}
    @objc func setShapeDefaults(_ sender:Any?) {
        guard let stroke=selectedShapes.first,let shape=stroke.shape else{return}
        colors[.pen]=NSColor(srgbRed:stroke.rgba[0],green:stroke.rgba[1],blue:stroke.rgba[2],alpha:stroke.rgba[3]);widths[.pen]=stroke.width
        shapeFill=shape.fill.map{NSColor(srgbRed:$0[0],green:$0[1],blue:$0[2],alpha:$0[3])};shapeFillFollowsPen=shape.effectiveFillMode == .border;rememberWritingPreferences();reader?.showNotice("当前图形样式已设为新图形默认样式。")
    }
    private var shapeStyleAction=false
    func finishShapeStyleEditing(){if shapeStyleAction {shapeStyleAction=false;session.finishAction()}}
    private func updateEraserSize(_ event:NSEvent) {
        guard tiltEraser,let altitude=NativePenInput.altitude(from:event) else{dynamicEraserRadius=nil;return}
        let target=EraserSizeResponse.radius(base:eraserRadius,altitude:altitude)
        dynamicEraserRadius=(dynamicEraserRadius ?? target)*0.35+target*0.65
    }
    private func armShapeHold(at point:CGPoint) {
        guard tool == .pen,automaticShapes,!suppressShape,snappedShape == nil else{return}
        if holdTimer != nil,hypot(point.x-holdPoint.x,point.y-holdPoint.y)*pdfView.scaleFactor<8 {return}
        holdTimer?.invalidate();holdPoint=point;holdPointCount=activeInkStroke?.points.count ?? 0
        let timer=Timer(timeInterval:0.65,repeats:false) {[weak self] _ in self?.recognizeHeldShape()};holdTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func recognizeHeldShape() {
        holdTimer?.invalidate();holdTimer=nil
        guard gesture,tool == .pen,automaticShapes,!suppressShape,snappedShape == nil,let page=activePage,let stroke=activeInkStroke, var shape=ShapeRecognition.recognize(stroke,scale:pdfView.scaleFactor) ?? ShapeRecognition.recognize(stroke,scale:pdfView.scaleFactor,trajectory:holdPointCount>=2 ? Array(stroke.points.prefix(holdPointCount)):nil) else{return}
        if shape.closed,let c=effectiveShapeFill?.usingColorSpace(.sRGB){shape.fillMode=shapeFillFollowsPen ? .border:.custom;shape.fill=shapeFillFollowsPen ? Array(stroke.rgba.prefix(3))+[c.alphaComponent]:[c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent]}
        snappedShape=shape;snapAnchor=shape.controls[0].cgPoint
        snapControl=shape.controls.max{hypot($0.x-snapAnchor.x,$0.y-snapAnchor.y)<hypot($1.x-snapAnchor.x,$1.y-snapAnchor.y)}!.cgPoint
        holdPoint=previous
        var snapped=stroke;snapped.shape=shape;snapped.points=shape.points;snapped.widthFactors=nil;snapped.outlines=nil;snapped.appearance=nil
        replace(page,ids:[stroke.id],with:[snapped]);presentation.invalidate(page,bounds:snapped.bounds.insetBy(dx:-4/pdfView.scaleFactor,dy:-4/pdfView.scaleFactor));reader?.updateParameters()
    }
    private func restoreActiveHandwriting() {
        guard let shape=snappedShape,let page=activePage,var stroke=activeInkStroke else{return}
        stroke.shape=nil;stroke.points=shape.originalPoints;stroke.outlines=shape.originalOutlines.isEmpty ? nil:shape.originalOutlines;stroke.appearance = shape.originalOutlines.isEmpty ? nil:.perfectFreehandV1;stroke.widthFactors=shape.originalOutlines.isEmpty ? nil:Array(repeating:1,count:stroke.points.count)
        replace(page,ids:[stroke.id],with:[stroke]);snappedShape=nil;suppressShape=true;reader?.updateParameters()
    }
    private(set) var activePage: PDFPage?
    private(set) var gesture = false
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var points: [CGPoint] = []
    private var activeInkID: UUID?
    private var inkBuilder: PenStrokeBuilding?
    private var markerBuilder: InkDirectBuilder?
    private var inputTrace: InkInputTrace?
    private var latestInputTimestamp: Double?
    private var previousCoalescing: Bool?

    private var draggingMove = false
    private var originalMove: [InkStroke] = []
    private var originalImages: [PageImage] = []
    private var originalMarks: [PageMark] = []
    private var objectResize = false
    private var objectResizeCorner = CGPoint.zero
    private var objectResizeAnchor = CGPoint.zero
    private var cropOriginal: PageImage?
    private var cropPreview: PageImage?
    private var cropStart = CGPoint.zero
    private var insertionReturnTool: ReaderTool?
    private var contextLocation: (PDFPage,CGPoint)?
    private(set) var selectionOutline: [CGPoint] = []
    private var originalOutline: [CGPoint] = []
    private var selectionPage: PDFPage?
    private(set) var selectedIDs = Set<UUID>()
    private var selectedHighlightID: UUID?
    private var clickedInkNote: (UUID,PageAnchor)?
    var selectedHighlight: PDFAnnotation? {
        guard let id=selectedHighlightID else{return nil}
        return selectionPage?.annotations.first { session.markID(for:$0) == id }
    }
    private var regionMode = false
    private var regionRelink: UUID?
    private var regionRect: CGRect?
    func beginRegion(relink:UUID?) { clearSelection(); regionMode=true; regionRelink=relink; regionRect=nil; refreshToolCursor(); NSCursor.crosshair.set() }
    var selectedNoteID:UUID? {
        if let id=selectedHighlightID {return session.annotations.note(for:id)?.id}
        if let clicked=clickedInkNote {return clicked.0}
        let ids=Set(selectedIDs.compactMap{session.annotations.note(for:$0)?.id})
        return ids.count==1 ? ids.first : nil
    }
    override func menu(for event:NSEvent)->NSMenu? {
        guard let reader else{return nil}
        contextLocation=location(event)
        selectedHighlightID=nil
        if let (page,p)=location(event),let mark=page.annotations.reversed().first(where:{($0.type=="Highlight" || $0.type=="Square") && $0.bounds.contains(p)}).flatMap({session.markID(for:$0)}) {
            selectedHighlightID=mark;selectionPage=page
        }
        let menu=NSMenu();menu.autoenablesItems=false
        let text=NSMenuItem(title:reader.noteCommandTitle,action:#selector(ReaderWindow.addNoteFromSelection),keyEquivalent:"")
        text.target=reader;text.isEnabled=reader.canPerformNoteCommand;menu.addItem(text)
        let paste=NSMenuItem(title:"粘贴图片",action:#selector(pasteImageAtContext(_:)),keyEquivalent:"");paste.target=self;paste.isEnabled = !session.annotationReadOnly && !session.currentFileIsReadOnly && ImageImport.canRead(.general);menu.addItem(paste)
        if let (page,p)=contextLocation,tool == .select || tool == .lasso,let id=objectHit(page,p) {selectObjects([id],on:page)}
        if !selectedIDs.isEmpty {menu.addItem(.separator());addObjectCommands(to:menu)}
        return menu
    }
    private var textStartPage: PDFPage?
    private var textStart = CGPoint.zero
    private var pendingLink: PDFAnnotation?
    private var hadDrag = false
    private var tracking: NSTrackingArea?
    private(set) var eraserHoverPoint: CGPoint?
    var eraserHoverBounds: CGRect? {
        guard let point=eraserHoverPoint,let reader else{return nil}
        let radius=effectiveEraserRadius * reader.pdfView.scaleFactor
        return CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)
    }

    var activeInkStroke: InkStroke? {
        guard let page = activePage, let id = activeInkID else { return nil }
        let strokes=session.inkStrokes(on:page)
        return strokes.last?.id==id ? strokes.last : strokes.first { $0.id == id }
    }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Leave native scrollbar dragging to NSScrollView, even in pen mode.
        if let scroll = reader?.pdfView.documentView?.enclosingScrollView {
            for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
                if !scroller.isHidden && scroller.alphaValue > 0 &&
                    scroller.bounds.contains(scroller.convert(local, from: self)) { return nil }
            }
        }
        return super.hitTest(point)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
        refreshToolCursor()
    }
    func clearSelection() {
        finishShapeStyleEditing()
        cropOriginal=nil;cropPreview=nil
        if selectionPage != nil { presentation.invalidateAll() }
        selectedIDs.removeAll(); selectionOutline = []; selectedHighlightID = nil; selectionPage = nil;clickedInkNote=nil
        needsDisplay = true; reader?.updateParameters()
    }
    func setTool(_ value: ReaderTool) {
        if regionMode { regionMode=false; regionRect=nil; regionRelink=nil; gesture=false; activePage=nil; presentation.invalidateAll(); NSCursor.arrow.set() }
        insertionReturnTool=nil
        finishInterruptedInput(); clearSelection(); pdfView.clearSelection()
        tool = value; refreshToolCursor(); needsDisplay = true
    }
    private func location(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return nil }
        let point = pdfView.convert(viewPoint, to: page)
        guard page.bounds(for: .cropBox).contains(point) else { return nil }
        return (page, point)
    }
    private func strokes(_ page: PDFPage) -> [InkStroke] { session.inkStrokes(on: page) }
    private func replace(_ page: PDFPage, ids: Set<UUID>, with strokes: [InkStroke]) {
        session.replaceInk(on: page, ids: ids, with: strokes)
        needsDisplay = true
    }
    private var selectedBounds: CGRect? {
        if let selectedHighlight { return selectedHighlight.bounds }
        guard let page = selectionPage else { return nil }
        return (strokes(page).filter { selectedIDs.contains($0.id) }.map(\.bounds)+session.images(on:page).filter{selectedIDs.contains($0.id)}.map(\.bounds)+session.annotations.marks.filter{selectedIDs.contains($0.id)}.map{$0.anchor.bounds}).reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
    }
    override func mouseDown(with event: NSEvent) {
        cancelPadInkZoom()
        let received = ProcessInfo.processInfo.systemUptime
        guard let reader else { return }
        // A duplicate down or missing up must not overwrite the original
        // coalescing setting or abandon the preceding document transaction.
        if activePage != nil || previousCoalescing != nil { finishInterruptedInput() }
        // The click that dismisses a parameter popover is consumed before it reaches a page.
        if reader.parameterPopover.isShown { reader.closeParameters(); return }
        reader.noteCard.commit()
        window?.makeFirstResponder(self)
        updateToolCursor(at:event.locationInWindow)
        guard let (page, p) = location(event) else { clearSelection(); return }
        eraserDidChange=false;dynamicEraserRadius=nil;snappedShape=nil;suppressShape=false;shapeResize=false;resizeShape=nil
        activePage = page; start = p; previous = p; points = [p]; hadDrag = false; pendingLink = nil;clickedInkNote=nil
        updateToolCursor(at:event.locationInWindow)
        if regionMode { gesture=true; regionRect=CGRect(origin:p,size:.zero); return }
        if session.annotationReadOnly && tool != .select { return }
        if tool == .select || tool == .lasso {
            if let crop=cropOriginal,page === selectionPage {
                cropStart=crop.sourcePoint(p);cropPreview=crop;gesture=true;return
            }
            if page === selectionPage,!selectedIDs.isEmpty {
                let groupBounds=selectedBounds
                let corners=groupBounds.map{[CGPoint(x:$0.minX,y:$0.minY),CGPoint(x:$0.maxX,y:$0.minY),CGPoint(x:$0.maxX,y:$0.maxY),CGPoint(x:$0.minX,y:$0.maxY)]} ?? []
                if let corner=corners.first(where:{hypot($0.x-p.x,$0.y-p.y)<8/pdfView.scaleFactor}),(!selectedImages.isEmpty || selectedIDs.count>1) {
                    objectResize=true;objectResizeCorner=corner
                    objectResizeAnchor=corners.max{hypot($0.x-corner.x,$0.y-corner.y)<hypot($1.x-corner.x,$1.y-corner.y)}!
                    beginObjectMove(page);return
                }
                if tool == .select,selectedIDs.count==1,let stroke=selectedShapes.first,let shape=stroke.shape,shape.controls.contains(where:{hypot($0.x-p.x,$0.y-p.y)<7/pdfView.scaleFactor}),!session.currentFileIsReadOnly {
                    gesture=true;shapeResize=true;resizeShape=shape;originalMove=[stroke];resizeOrigin=shape.controls.max{hypot($0.x-p.x,$0.y-p.y)<hypot($1.x-p.x,$1.y-p.y)}!.cgPoint
                    _=startAction("调整图形尺寸");return
                }
                if (tool == .lasso && InkGeometry.contains(p,polygon:selectionOutline)) || (tool == .select && groupBounds?.contains(p)==true) {beginObjectMove(page);return}
            }
            if tool == .select,let id=objectHit(page,p) {
                let ids=event.modifierFlags.contains(.shift) && page === selectionPage ? selectedIDs.union([id]):[id]
                selectObjects(ids,on:page);beginObjectMove(page);return
            }
            if insertionReturnTool != nil,tool == .select {completeImageEditing();activePage=nil;return}
        }
        if tool == .select || tool == .textHighlight {
            if tool == .select, let link = page.annotations.reversed().first(where: { $0.type == "Link" && $0.bounds.contains(p) }) {
                clearSelection(); pendingLink = link; textStartPage = page; textStart = p
                pdfView.clearSelection()
                return
            }
            clearSelection()
            selectedHighlightID = page.annotations.reversed().first { ($0.type == "Highlight" || $0.type == "Square") && $0.bounds.contains(p) }.flatMap { session.markID(for:$0) }
            if tool == .select,selectedHighlightID == nil,
               let stroke=strokes(page).reversed().first(where:{stroke in
                   guard session.annotations.note(for:stroke.id) != nil else{return false}
                   let radius=max(stroke.width/2,4/pdfView.scaleFactor)
                   return InkGeometry.erase(stroke,center:p,radius:radius) != [stroke]
               }),let note=session.annotations.note(for:stroke.id) {
                clickedInkNote=(note.id,session.pageAnchor(page:page,bounds:stroke.bounds))
            }
            selectionPage = selectedHighlightID == nil ? nil : page
            textStartPage = page; textStart = p
            pdfView.clearSelection(); reader.updateParameters(); needsDisplay = true
            return
        }
        clearTextSelection()
        gesture = true
        if tool == .lasso, page === selectionPage, !selectedIDs.isEmpty, InkGeometry.contains(p, polygon: selectionOutline) {
            beginObjectMove(page);return
        } else {
            clearSelection(); draggingMove = false
            if tool == .pen || tool == .marker {
                previousCoalescing = NSEvent.isMouseCoalescingEnabled
                NSEvent.isMouseCoalescingEnabled = false
                guard startAction(tool == .pen ? "书写" : "自由荧光笔") else {
                    restoreCoalescing(); return
                }
                let c = colors[tool]!.usingColorSpace(.sRGB)!
                var stroke = InkStroke(points: [InkPoint(p)], width: widths[tool]!,
                    rgba: [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent],
                    kind: tool == .marker ? .marker : .pen)
                if tool == .pen {
                    InkRuntimeReport.record(window:window,scale:pdfView.scaleFactor,penDown:true)
                    inkBuilder=PenEngine.make(point:InkPoint(p),width:stroke.width,pressure:penPressure(event),timestamp:event.timestamp,viewScale:pdfView.scaleFactor,sensitivity:pressureSensitivity)
                    stroke.widthFactors=inkBuilder?.initialFactors;stroke.appearance = .perfectFreehandV1;stroke.outlines=inkBuilder?.initialOutlines
                }
                else {markerBuilder=InkDirectBuilder(point:InkPoint(p))}
                if EcruEnvironment.value("ECRU_INPUT_TRACE_DIR") != nil {
                    inputTrace = InkInputTrace(id: stroke.id, scale: pdfView.scaleFactor, width: stroke.width, kind: stroke.kind)
                    inputTrace?.penResponse = tool == .pen ? PenEngine.recipe : "direct-marker-v1"
                    inputTrace?.pageIndex = session.document.index(for: page)
                    inputTrace?.mouseCoalescingEnabled = NSEvent.isMouseCoalescingEnabled
                    inputTrace?.captureVersion=2;inputTrace?.drawCallbacks=[]
                }
                guard stroke.isValid else {
                    finishInterruptedInput()
                    reader.showNotice("笔迹引擎未能开始此笔，请重新落笔。")
                    return
                }
                activeInkID = stroke.id
                session.replaceInk(on: page, ids: [], with: [stroke])
                recordInput(event, raw: p, point: p, received: received)
            }
            if tool == .pen {armShapeHold(at:p)}
            if tool == .eraser {
                updateEraserSize(event);guard startAction("局部擦除") else{return}
                if EcruEnvironment.value("ECRU_INPUT_TRACE_DIR") != nil {
                    inputTrace=InkInputTrace(id:UUID(),scale:pdfView.scaleFactor,width:eraserRadius*2,kind:.pen)
                    inputTrace?.inputTool="eraser";inputTrace?.penResponse="tilt-eraser-v1";inputTrace?.captureVersion=3;inputTrace?.pageIndex=session.document.index(for:page)
                }
                erase(at:p,on:page);recordInput(event,raw:p,point:p,received:received)
            }
        }
        needsDisplay = true
    }
    private func restoreCoalescing() {
        if let previousCoalescing { NSEvent.isMouseCoalescingEnabled = previousCoalescing }
        previousCoalescing = nil
    }
    deinit { holdTimer?.invalidate();restoreCoalescing() }
    private func clearTextSelection() { pdfView.clearSelection(); textStartPage = nil }
    private func startAction(_ label:String) -> Bool {
        let began = session.beginInkAction(label)
        guard began else { gesture = false; activePage = nil; reader?.refresh(); return false }
        return true
    }
    override func mouseDragged(with event: NSEvent) {
        let received = ProcessInfo.processInfo.systemUptime
        guard let page = activePage else { return }
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        var p = pdfView.convert(viewPoint, to: page)
        if regionMode {
            let crop=page.bounds(for:.cropBox)
            p.x=min(max(p.x,crop.minX),crop.maxX); p.y=min(max(p.y,crop.minY),crop.maxY)
            regionRect=CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y))
            presentation.invalidate(page,bounds:crop); return
        }
        let rawPoint = p
        let b = page.bounds(for: .cropBox)
        if gesture, (tool == .pen || tool == .marker), !b.contains(p), let id = activeInkID {
            // End at the first page boundary. Repeated out-of-page samples must
            // never become a spurious line along the paper edge or toolbar.
            let dx = p.x-previous.x, dy = p.y-previous.y
            var t: CGFloat = 1
            if dx > 0 { t = min(t, (b.maxX-previous.x)/dx) }
            if dx < 0 { t = min(t, (b.minX-previous.x)/dx) }
            if dy > 0 { t = min(t, (b.maxY-previous.y)/dy) }
            if dy < 0 { t = min(t, (b.minY-previous.y)/dy) }
            p = CGPoint(x: previous.x+dx*max(0,t), y: previous.y+dy*max(0,t))
            appendInput(p, event: event, id: id, page: page)
            recordInput(event, raw: rawPoint, point: p, received: received)
            previous = p; finishInput(); return
        }
        // A lasso records the pointer's actual trajectory, including excursions
        // beyond the page. Clamping would replace that trajectory with page edges.
        if tool != .lasso || draggingMove {
            p.x = min(max(p.x, b.minX), b.maxX); p.y = min(max(p.y, b.minY), b.maxY)
        }
        hadDrag = hadDrag || hypot(p.x-start.x, p.y-start.y) > 1.5 / pdfView.scaleFactor
        if let crop=cropOriginal,gesture {
            let q=crop.sourcePoint(p)
            let region=CGRect(x:min(cropStart.x,q.x),y:min(cropStart.y,q.y),width:abs(q.x-cropStart.x),height:abs(q.y-cropStart.y))
            cropPreview=crop.cropped(to:region);presentation.invalidateAll();return
        }
        if draggingMove,gesture {
            if objectResize {
                let dx=objectResizeCorner.x-objectResizeAnchor.x,dy=objectResizeCorner.y-objectResizeAnchor.y
                let minimum=max(0.05,originalImages.map{max(0.1/$0.rect.width,0.1/$0.rect.height)}.max() ?? 0.05)
                let factor=max(minimum,min(100,((p.x-objectResizeAnchor.x)*dx+(p.y-objectResizeAnchor.y)*dy)/max(dx*dx+dy*dy,0.01)))
                applyObjectTransform(CGAffineTransform(translationX:objectResizeAnchor.x,y:objectResizeAnchor.y).scaledBy(x:factor,y:factor).translatedBy(x:-objectResizeAnchor.x,y:-objectResizeAnchor.y),scale:factor,on:page)
            } else {applyObjectTransform(CGAffineTransform(translationX:p.x-start.x,y:p.y-start.y),scale:1,on:page)}
            return
        }
        if tool == .select || tool == .textHighlight {
            if hadDrag, let firstPage = textStartPage {
                selectedHighlightID = nil; selectionPage = nil;clickedInkNote=nil; reader?.updateParameters()
                let endPage = pdfView.page(for: viewPoint, nearest: true) ?? page
                let end = pdfView.convert(viewPoint, to: endPage)
                let selection = session.document.selection(from: firstPage, at: textStart, to: endPage, at: end)
                pdfView.setCurrentSelection(selection, animate: false)
            }
            return
        }
        guard gesture else { return }
        if shapeResize,let shape=resizeShape,var stroke=originalMove.first {
            stroke.shape=shape.resized(from:resizeOrigin,to:p);stroke.points=stroke.shape!.points;replace(page,ids:[stroke.id],with:[stroke])
        } else if draggingMove {
            selectionOutline = originalOutline.map { CGPoint(x: $0.x + p.x-start.x, y: $0.y + p.y-start.y) }
            replace(page, ids: selectedIDs, with: originalMove.map { $0.translated(dx: p.x-start.x, dy: p.y-start.y) })
        } else if tool == .eraser {
            let priorRadius=effectiveEraserRadius
            updateEraserSize(event)
            let nextRadius=effectiveEraserRadius
            let distance = hypot(p.x-previous.x, p.y-previous.y)
            let steps = max(1, Int(ceil(distance / max(1, effectiveEraserRadius / 2))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                if dynamicEraserRadius != nil {dynamicEraserRadius=priorRadius+(nextRadius-priorRadius)*t}
                erase(at: CGPoint(x: previous.x + (p.x-previous.x)*t, y: previous.y + (p.y-previous.y)*t), on: page)
            }
            recordInput(event,raw:rawPoint,point:p,received:received)
        } else if let id = activeInkID {
            appendInput(p, event: event, id: id, page: page)
            recordInput(event, raw: rawPoint, point: p, received: received)
        } else { points.append(p) }
        previous = p
        updateToolCursor(at:event.locationInWindow)
        // Ink updates invalidate their page-local damage through the session.
        // Clearing the entire transparent viewport on every sample adds a second
        // backing-store redraw without displaying any additional ink.
        if tool != .pen && tool != .marker { needsDisplay = true }
    }
    private func erase(at p: CGPoint, on page: PDFPage) {
        for stroke in strokes(page) {
            guard stroke.bounds.insetBy(dx: -effectiveEraserRadius, dy: -effectiveEraserRadius).contains(p) else { continue }
            let fragments = InkGeometry.erase(stroke, center: p, radius: effectiveEraserRadius)
            if fragments != [stroke] { eraserDidChange=true;session.replaceInk(on: page, ids: [stroke.id], with: fragments) }
        }
        needsDisplay = true
    }
    private func penPressure(_ event: NSEvent) -> Double? {
        pressureEnabled ? NativePenInput.pressure(from: event):nil
    }
    private func appendInput(_ p: CGPoint, event: NSEvent, id: UUID, page: PDFPage) {
        if let shape=snappedShape,var stroke=activeInkStroke {
            if event.type != .leftMouseUp {
                let target=CGPoint(x:snapControl.x+p.x-holdPoint.x,y:snapControl.y+p.y-holdPoint.y)
                stroke.shape=shape.resized(from:snapAnchor,to:target);stroke.points=stroke.shape!.points;replace(page,ids:[id],with:[stroke])
            };return
        }
        if let builder=inkBuilder {
            let update=builder.append(InkPoint(p),pressure:penPressure(event),isRelease:event.type == .leftMouseUp,timestamp:event.timestamp)
            if builder.generatedCount>99_900 {finishInterruptedInput();return}
            session.updatePerfectInk(update,to:id,on:page)
            if event.type != .leftMouseUp {armShapeHold(at:p)}
            if builder.capacityReached { finishInterruptedInput() }
        } else if var builder=markerBuilder {
            let generated=builder.append(InkPoint(p));markerBuilder=builder
            if builder.generatedCount>99_900 {finishInterruptedInput();return}
            session.appendInkPoints(generated.points,to:id,on:page)
        }
    }
    private func recordInput(_ event: NSEvent, raw: CGPoint, point: CGPoint, received: Double) {
        latestInputTimestamp = event.timestamp
        let cg=event.cgEvent,device=cg?.getIntegerValueField(.tabletEventDeviceID)
        let correlation=UInt64(bitPattern:cg?.getIntegerValueField(.eventSourceUserData) ?? 0)
        let padInk=device == 0x5049 && correlation != 0
        inputTrace?.samples.append(InkInputSample(point: InkPoint(point), rawPoint: InkPoint(raw),
            timestamp: event.timestamp, received: received, handled: ProcessInfo.processInfo.systemUptime,
            type: event.type.rawValue, subtype: event.subtype.rawValue, pressure: event.pressure,
            tablet: event.subtype == .tabletPoint || event.type == .tabletPoint || device == 0x5049,
            windowPoint:InkPoint(event.locationInWindow),quartzPoint:cg.map{InkPoint($0.location)},deviceID:device,
            forwardedGesture:padInk ? UInt32(truncatingIfNeeded:correlation>>32) : nil,
            forwardedSequence:padInk ? UInt32(truncatingIfNeeded:correlation) : nil,
            submitted:ProcessInfo.processInfo.systemUptime, nativePressure:NativePenInput.pressure(from:event),nativeAltitude:NativePenInput.altitude(from:event),eraserRadius:tool == .eraser ? effectiveEraserRadius:nil))
    }
    func inkDrawCompleted(on page:PDFPage,started:Double) {
        guard page === activePage,let count=inputTrace?.samples.count,count>0 else{return}
        inputTrace?.drawCallbacks?.append(InkDrawCallback(throughSample:count,started:started,completed:ProcessInfo.processInfo.systemUptime))
    }
    override func mouseUp(with event: NSEvent) {
        let received = ProcessInfo.processInfo.systemUptime
        if gesture, let id = activeInkID, let page = activePage {
            let raw = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
            let b = page.bounds(for: .cropBox)
            var p = raw
            if !b.contains(raw) {
                // Match drag boundary handling even if up is the first event
                // outside the paper; component clamping would invent an edge line.
                let dx=raw.x-previous.x,dy=raw.y-previous.y
                var t:CGFloat=1
                if dx>0 {t=min(t,(b.maxX-previous.x)/dx)}
                if dx<0 {t=min(t,(b.minX-previous.x)/dx)}
                if dy>0 {t=min(t,(b.maxY-previous.y)/dy)}
                if dy<0 {t=min(t,(b.minY-previous.y)/dy)}
                p=CGPoint(x:previous.x+dx*max(0,t),y:previous.y+dy*max(0,t))
            }
            appendInput(p, event: event, id: id, page: page)
            recordInput(event, raw: raw, point: p, received: received)
        }
        if gesture, tool == .lasso, !draggingMove, let page = activePage {
            let p = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
            if points.last != p { points.append(p) }
        }
        if gesture,tool == .eraser,let (_,p)=location(event) {recordInput(event,raw:p,point:p,received:received)}
        // Mouse-up does not erase again: show the last point actually erased.
        updateToolCursor(at:event.locationInWindow)
        let returnToPen=gesture && tool == .eraser && eraserDidChange && automaticPenReturn && NativePenInput.completedContact(event)
        finishInput()
        if returnToPen {setTool(.pen);reader?.refresh()}
    }
    func finishInterruptedInput() { cancelPadInkZoom(); inputTrace?.interrupted = true; finishInput(); restoreCoalescing(); refreshToolCursor() }
    private func finishInput() {
        holdTimer?.invalidate();holdTimer=nil
        guard let page = activePage else { return }
        if let stroke=activeInkStroke,stroke.shape != nil {presentation.invalidate(page,bounds:stroke.bounds.insetBy(dx:-4/pdfView.scaleFactor,dy:-4/pdfView.scaleFactor))}
        if regionMode {
            let rect=regionRect; let relink=regionRelink
            regionMode=false; regionRect=nil; regionRelink=nil; gesture=false; activePage=nil; refreshToolCursor()
            presentation.invalidate(page,bounds:page.bounds(for:.cropBox))
            if let rect,let id=session.addRegion(page:page,rect:rect,to:relink) { reader?.showNote(id,focus:true,anchor:session.pageAnchor(page:page,bounds:rect),provisional:relink == nil ? false : nil) }
            return
        }
        defer {
            restoreCoalescing()
            inputTrace?.finished = ProcessInfo.processInfo.systemUptime
            inkBuilder?.finish(); inputTrace?.save(); inputTrace = nil; inkBuilder = nil; markerBuilder=nil; latestInputTimestamp = nil
            activePage = nil; activeInkID = nil; snappedShape=nil;resizeShape=nil;shapeResize=false;dynamicEraserRadius=nil;gesture = false; draggingMove = false; originalMove = []; originalImages=[];originalMarks=[];objectResize=false; originalOutline = []; points = []
            textStartPage = nil; reader?.updateParameters()
            if tool != .pen && tool != .marker { pdfView.needsDisplay = true }
            needsDisplay = true
        }
        if cropOriginal != nil {return}
        if tool == .select, !hadDrag, let link = pendingLink {
            if let destination = link.destination { reader?.navigate(to: destination) }
            else if let action = link.action as? PDFActionGoTo { reader?.navigate(to: action.destination) }
            else if let action = link.action as? PDFActionURL, let url = action.url, ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        }
        pendingLink = nil
        if tool == .textHighlight, hadDrag, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            session.addTextSelection(selection,color:colors[.textHighlight]!,withNote:false)
            pdfView.clearSelection()
        } else if (tool == .textHighlight || tool == .select), selectedHighlight == nil, pendingLink == nil, (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reader?.showNotice("此页没有可选择文字；文字选择与文字高亮不可用，可继续使用笔或自由荧光笔。")
        }
        if tool == .select, !hadDrag, let id=selectedHighlightID,let note=session.annotations.note(for:id) { reader?.showNote(note.id,anchor:session.annotations.marks.first{$0.id==id}?.anchor ?? session.pageAnchor(page:page,bounds:selectedHighlight?.bounds ?? page.bounds(for:.cropBox))) }
        if tool == .select,!hadDrag,let (id,anchor)=clickedInkNote {reader?.showNote(id,anchor:anchor)}
        if tool == .select,!hadDrag,!selectedIDs.isEmpty,let id=selectedNoteID,let r=selectedBounds {reader?.showNote(id,anchor:session.pageAnchor(page:page,bounds:r))}
        if tool == .select {reader?.selectionChanged()}
        if gesture {
            if tool == .lasso && !draggingMove && points.count >= 3 {
                selectedIDs = session.annotations.expanded(Set(strokes(page).filter { InkGeometry.isFullyInside($0, polygon: points) }.map(\.id)+session.images(on:page).filter{image in image.corners.allSatisfy{InkGeometry.contains($0,polygon:points)}}.map(\.id)+session.annotations.marks.filter{mark in mark.anchor.page==session.document.index(for:page) && [CGPoint(x:mark.anchor.bounds.minX,y:mark.anchor.bounds.minY),CGPoint(x:mark.anchor.bounds.maxX,y:mark.anchor.bounds.maxY)].allSatisfy{InkGeometry.contains($0,polygon:points)}}.map(\.id)))
                selectionPage = selectedIDs.isEmpty ? nil : page
                selectionOutline = selectedIDs.isEmpty ? [] : points
            }
            if tool != .lasso || draggingMove || shapeResize { session.finishAction() }
        }
    }
    func deleteSelected() {
        guard let page = selectionPage else { return }
        if let id=selectedHighlightID { session.removeMark(id) }
        else { guard !session.currentFileIsReadOnly,session.beginInkAction("删除所选对象") else{return}; session.replaceObjects(on:page,ids:selectedIDs,ink:[],images:[]) }
        clearSelection(); session.finishAction(); pdfView.needsDisplay = true
    }
    var hasDeletableSelection: Bool { selectedHighlight != nil || !selectedIDs.isEmpty }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if cropOriginal != nil {cancelCrop();return}
            if insertionReturnTool != nil {completeImageEditing();return}
            if snappedShape != nil {restoreActiveHandwriting();return}
            // Escape cancels a pending repair rectangle, but commits received ink
            // once, including its action history and the coalescing lease.
            if regionMode { regionMode=false; regionRect=nil; regionRelink=nil; gesture=false; activePage=nil }
            finishInterruptedInput(); presentation.invalidateAll(); refreshToolCursor(); reader?.closeParameters(); clearSelection(); return
        }
        if event.keyCode == 51 || event.keyCode == 117 { if hasDeletableSelection { deleteSelected() }; return }
        super.keyDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !gesture else { return }
        pdfView.documentView?.enclosingScrollView?.scrollWheel(with: event)
        reader?.positionNoteUI();needsDisplay = true
    }
    // Shared native PDF path for trackpad magnification and PadInk bridge v1.
    // Resolve the PDF coordinate BEFORE changing scale, then put it beneath the
    // new centroid. This also permits translation during an established pinch.
    func zoomPDF(logDelta: Double, from oldCenter: CGPoint, to center: CGPoint) {
        guard !gesture, logDelta.isFinite, abs(logDelta) <= 1 else { return }
        let oldPoint = pdfView.convert(oldCenter, from: nil)
        guard let page = pdfView.page(for: oldPoint, nearest: true) else { return }
        let anchor = pdfView.convert(oldPoint, to: page)
        reader?.closeParameters()
        if logDelta != 0 {
            pdfView.autoScales = false
            pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor,
                                                                pdfView.scaleFactor * exp(logDelta)))
            pdfView.layoutDocumentView()
        }
        if let document = pdfView.documentView, let scroll = document.enclosingScrollView {
            let desired = document.convert(center, from: nil)
            let actual = document.convert(pdfView.convert(anchor, from: page), from: pdfView)
            let clip = scroll.contentView
            let proposed = CGRect(origin: CGPoint(x: clip.bounds.minX + actual.x-desired.x,
                                                   y: clip.bounds.minY + actual.y-desired.y), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        }
        reader?.positionNoteUI(); reader?.refresh(); needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard event.magnification > -1 else { return }
        zoomPDF(logDelta: log(1 + event.magnification), from: event.locationInWindow, to: event.locationInWindow)
    }
    private var padInkCenter: CGPoint?
    func cancelPadInkZoom() { padInkCenter = nil }
    /// Called by the window-local input scope, including when the moving center
    /// crosses a note overlay. Only a gesture that began on the canvas is admitted.
    static func isPadInkZoom(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x50494E4B0001
    }
    func handlePadInkZoom(_ event: NSEvent) -> Bool {
        guard Self.isPadInkZoom(event), let cg = event.cgEvent else { return false }
        let phase = cg.getIntegerValueField(.scrollWheelEventScrollPhase)
        if phase == 4 || phase == 8 { cancelPadInkZoom(); return true }
        guard !gesture, window?.isKeyWindow == true, NSApp.isActive,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25,
              event.timestamp <= ProcessInfo.processInfo.systemUptime + 0.01 else { cancelPadInkZoom(); return true }
        // Process-targeted events bypass WindowServer hit routing and have
        // windowNumber 0. Convert Quartz global coordinates in the key reader.
        guard let window, let primary = NSScreen.screens.first else { cancelPadInkZoom(); return true }
        let center = event.window == nil
            ? window.convertPoint(fromScreen: CGPoint(x: cg.location.x, y: primary.frame.maxY-cg.location.y))
            : event.locationInWindow
        if phase == 1 {
            cancelPadInkZoom()
            if let content = window.contentView,
               content.hitTest(content.convert(center, from: nil)) === self { padInkCenter = center }
        } else if phase == 2, let oldCenter = padInkCenter {
            let delta = Double(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)) / 1_000_000
            guard abs(delta) <= 1 else { cancelPadInkZoom(); return true }
            zoomPDF(logDelta: delta, from: oldCenter, to: center)
            padInkCenter = center
        } else { cancelPadInkZoom() }
        return true
    }
    // Transparent cursor image is scoped by AppKit cursor rectangles, without
    // process/global hide counters. ScreenCaptureKit receives the same image.
    static let paperCursor = NSCursor(image:NSImage(size:NSSize(width:16,height:16),flipped:false) { _ in true },hotSpot:.zero)
    var menuTracking = false
    var usesPaperCursor: Bool { !regionMode && [.pen,.marker,.eraser].contains(tool) }
    func cursorless(at windowPoint:CGPoint) -> Bool {
        guard usesPaperCursor, !menuTracking, NSApp.isActive, let window,
              window.isKeyWindow, reader != nil, let content=window.contentView,
              content.hitTest(content.convert(windowPoint,from:nil)) === self else { return false }
        let viewPoint=pdfView.convert(windowPoint,from:nil)
        guard let page=pdfView.page(for:viewPoint,nearest:false) else{return false}
        return page.bounds(for:.cropBox).contains(pdfView.convert(viewPoint,to:page))
    }
    func updateToolCursor(at point:CGPoint) {
        let onPaper=cursorless(at:point)
        let nextHover = onPaper && tool == .eraser ? convert(point,from:nil) : nil
        if eraserHoverPoint != nil || nextHover != nil {needsDisplay=true}
        eraserHoverPoint=nextHover
        if onPaper {Self.paperCursor.set()}
        else if NSCursor.current === Self.paperCursor {NSCursor.arrow.set()}
        else if regionMode {NSCursor.crosshair.set()}
    }
    func refreshToolCursor() {
        guard let window else {return}
        window.invalidateCursorRects(for:self)
        updateToolCursor(at:window.mouseLocationOutsideOfEventStream)
    }
    override func resetCursorRects() {
        guard usesPaperCursor,!menuTracking,window?.isKeyWindow == true,NSApp.isActive,reader != nil else{return}
        for page in pdfView.visiblePages {
            let rect=convert(pdfView.convert(page.bounds(for:.cropBox),from:page),from:pdfView).intersection(visibleRect)
            if !rect.isEmpty {addCursorRect(rect,cursor:Self.paperCursor)}
        }
    }
    override func cursorUpdate(with event:NSEvent) {updateToolCursor(at:event.locationInWindow)}
    override func mouseEntered(with event:NSEvent) {updateToolCursor(at:event.locationInWindow)}
    override func mouseMoved(with event:NSEvent) {updateToolCursor(at:event.locationInWindow)}
    override func mouseExited(with event:NSEvent) {
        eraserHoverPoint=nil;needsDisplay=true
        if NSCursor.current === Self.paperCursor {NSCursor.arrow.set()}
    }
    private func viewPoint(_ p: CGPoint, page: PDFPage) -> CGPoint { convert(pdfView.convert(p, from: page), from: pdfView) }
    // Called inside the page overlay's drawing context; PDFKit owns its transform.
    func drawPageDecorations(_ page: PDFPage, in overlay: PageInkView, dirtyRect: CGRect) {
        func viewPoint(_ p: CGPoint, page: PDFPage) -> CGPoint {
            overlay.convert(pdfView.convert(p, from: page), from: pdfView)
        }
        let origin = viewPoint(.zero, page: page)
        let xAxis = viewPoint(CGPoint(x: 1, y: 0), page: page)
        let scale = hypot(xAxis.x-origin.x, xAxis.y-origin.y)
        let screenScale = max(pdfView.scaleFactor, 0.001)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: overlay.bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if page === activePage, let rect=regionRect {
            let converted=overlay.convert(pdfView.convert(rect,from:page),from:pdfView)
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect:converted).stroke()
        }
        if page === activePage,let stroke=activeInkStroke,let shape=stroke.shape {
            for p in shape.controls {
                let p=viewPoint(p.cgPoint,page:page),r=3*scale/screenScale
                let dot=NSBezierPath(ovalIn:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2));NSColor.controlAccentColor.setFill();dot.fill()
            }

        }
        if page === activePage, let timestamp = latestInputTimestamp {
            // Pair: newest received event represented in this draw, draw completion uptime.
            inputTrace?.displayedThrough.append(contentsOf: [timestamp, ProcessInfo.processInfo.systemUptime])
        }
        if page === activePage, gesture, !draggingMove, tool == .lasso, let first = points.first {
            let path = NSBezierPath(); path.move(to: viewPoint(first, page: page))
            for point in points.dropFirst() { path.line(to: viewPoint(point, page: page)) }
            // While dragging, show only the sampled pointer trajectory. The
            // implicit closing segment is added only when selection completes.
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5 * scale / screenScale
            path.setLineDash([5,3], count: 2, phase: 0); path.stroke()
        }
        if page === selectionPage, !selectedIDs.isEmpty, let first = selectionOutline.first {
            let outline = NSBezierPath()
            outline.move(to: viewPoint(first, page: page))
            for p in selectionOutline.dropFirst() { outline.line(to: viewPoint(p, page: page)) }
            outline.close(); outline.windingRule = .evenOdd
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); outline.fill()
            NSColor.controlAccentColor.setStroke(); outline.lineWidth = 1.5 * scale / screenScale
            outline.setLineDash([5,3], count: 2, phase: 0); outline.stroke()
        }
        if page === selectionPage,(!selectedImages.isEmpty || selectedIDs.count>1),let r=selectedBounds {
            for point in [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)] {
                let p=viewPoint(point,page:page),radius=4*scale/screenScale
                let grip=NSBezierPath(rect:CGRect(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2));NSColor.windowBackgroundColor.setFill();grip.fill();NSColor.controlAccentColor.setStroke();grip.lineWidth=scale/screenScale;grip.stroke()
            }
        }
        if page === selectionPage {
            for stroke in selectedShapes {
                for p in stroke.shape!.controls {
                    let p=viewPoint(p.cgPoint,page:page),r=3.5*scale/screenScale
                    let dot=NSBezierPath(ovalIn:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2));NSColor.windowBackgroundColor.setFill();dot.fill();NSColor.controlAccentColor.setStroke();dot.lineWidth=scale/screenScale;dot.stroke()
                }
            }
        }
        if page === selectionPage, selectedHighlight?.type == "Square",let rect = selectedHighlight?.bounds {
            let converted = overlay.convert(pdfView.convert(rect, from: page), from: pdfView).insetBy(dx: -3 * scale / screenScale, dy: -3 * scale / screenScale)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); NSBezierPath(rect: converted).fill()
            NSColor.controlAccentColor.setStroke(); let border = NSBezierPath(rect: converted); border.lineWidth = 1.5 * scale / screenScale; border.stroke()
        }
    }
    // Only the eraser affordance belongs to viewport space. Ink remains in page overlays.
    override func draw(_ dirtyRect:NSRect) {
        guard let rect=eraserHoverBounds,let point=eraserHoverPoint,let reader else{return}
        let viewPoint=reader.pdfView.convert(point,from:self)
        guard let page=reader.pdfView.page(for:viewPoint,nearest:false) else{return}
        NSGraphicsContext.saveGraphicsState()
        defer {NSGraphicsContext.restoreGraphicsState()}
        let paper=convert(reader.pdfView.convert(page.bounds(for:.cropBox),from:page),from:reader.pdfView)
        NSBezierPath(rect:paper.intersection(bounds)).addClip()
        NSColor.secondaryLabelColor.setStroke()
        let ring=NSBezierPath(ovalIn:rect);ring.lineWidth=1;ring.stroke()
    }
}
