import AppKit
import PDFKit

@main enum Probe {
 static func main() throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/complex-pdf")
  let out=root.appendingPathComponent("pdfkit-probe");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  print("name,encrypted,commenting,searchMatches,exportEncrypted,exportFeatures,graphPreserved")
  for name in ["ordinary","acroform","attachments","password","restricted","signed","xfa-static","active","portfolio","combined"] {
   let input=try Data(contentsOf:root.appendingPathComponent("fixtures/"+name+".pdf"))
   let doc=PDFDocument(data:input)!
   if doc.isLocked { _=doc.unlock(withPassword:"reader-secret") }
   guard let export=doc.dataRepresentation(),let reopened=PDFDocument(data:export) else { print(name+",exportFailed");continue }
   try export.write(to:out.appendingPathComponent(name+".pdf"))
   let flags=(try? PDFPagePreservation.inspect(export,password:reopened.isLocked ? "reader-secret" : nil).features).map(String.init) ?? "unparsed"
   print("\(name),\(doc.isEncrypted),\(doc.allowsCommenting),\(doc.findString("compatibility",withOptions:[]).count),\(reopened.isEncrypted),\(flags),\(PDFPagePreservation.validate(input,saved:export,removing:[[],[]]))")
  }
 }
}
