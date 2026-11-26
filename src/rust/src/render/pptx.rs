//! A minimal, deterministic `.pptx` package around DrawingML fragments.
//!
//! One slide per fragment, on a blank layout of a plain master and theme: the
//! smallest package PowerPoint opens without a repair prompt. The zip is
//! written here (deflate from `flate2`, already in the dependency tree through
//! `png` and `krilla`) with fixed timestamps and no user or date metadata, so
//! the same scenes always give the same bytes.

use super::dml::{dml_escape, resolve_media, DML_NS};
use std::collections::HashMap;
use std::io::Write;

/// One slide: a DrawingML fragment (media tokenised) and its PNGs.
pub struct SlidePart {
    pub xml: String,
    pub media: Vec<Vec<u8>>,
}

const CT_NS: &str = "http://schemas.openxmlformats.org/package/2006/content-types";
const REL_NS: &str = "http://schemas.openxmlformats.org/package/2006/relationships";
const R_DOC: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const XML_DECL: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";

/// The `.pptx` bytes for `slides` on a `cx` x `cy` EMU slide.
pub fn pptx_package(slides: &[SlidePart], cx: i64, cy: i64, title: &str) -> Vec<u8> {
    let mut z = ZipWriter::default();
    let n = slides.len();

    // Media: one part per distinct image across the deck.
    let mut media_parts: Vec<Vec<u8>> = Vec::new();
    let mut media_index: HashMap<u64, usize> = HashMap::new();
    let mut slide_xml: Vec<(String, String)> = Vec::with_capacity(n);
    for s in slides {
        // Slide-level relationship ids: rId1 is the layout, images follow.
        let mut rels = format!(
            "<Relationship Id=\"rId1\" Type=\"{R_DOC}/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
        );
        let mut ids: Vec<usize> = Vec::with_capacity(s.media.len());
        for (i, png) in s.media.iter().enumerate() {
            let key = super::dml::fnv64(png);
            let part = *media_index.entry(key).or_insert_with(|| {
                media_parts.push(png.clone());
                media_parts.len()
            });
            ids.push(part);
            rels.push_str(&format!(
                "<Relationship Id=\"rId{}\" Type=\"{R_DOC}/image\" Target=\"../media/image{part}.png\"/>",
                i + 2
            ));
        }
        let frag = renumber_ids(&resolve_media(&s.xml, |i| format!("rId{}", i + 2)));
        let xml = format!(
            "{XML_DECL}<p:sld {DML_NS}><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/>\
             <p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/>\
             <a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm>\
             </p:grpSpPr>{frag}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
        );
        let rels = format!("{XML_DECL}<Relationships xmlns=\"{REL_NS}\">{rels}</Relationships>");
        slide_xml.push((xml, rels));
    }

    // [Content_Types].xml first, as the format recommends.
    let mut ct = format!(
        "{XML_DECL}<Types xmlns=\"{CT_NS}\">\
         <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\
         <Default Extension=\"xml\" ContentType=\"application/xml\"/>\
         <Default Extension=\"png\" ContentType=\"image/png\"/>\
         <Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>\
         <Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>\
         <Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>\
         <Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>\
         <Override PartName=\"/ppt/presProps.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presProps+xml\"/>\
         <Override PartName=\"/ppt/viewProps.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml\"/>\
         <Override PartName=\"/ppt/tableStyles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml\"/>\
         <Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>\
         <Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
    );
    for i in 1..=n {
        ct.push_str(&format!(
            "<Override PartName=\"/ppt/slides/slide{i}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        ));
    }
    ct.push_str("</Types>");
    z.add("[Content_Types].xml", ct.as_bytes());

    z.add(
        "_rels/.rels",
        format!(
            "{XML_DECL}<Relationships xmlns=\"{REL_NS}\">\
             <Relationship Id=\"rId1\" Type=\"{R_DOC}/officeDocument\" Target=\"ppt/presentation.xml\"/>\
             <Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>\
             <Relationship Id=\"rId3\" Type=\"{R_DOC}/extended-properties\" Target=\"docProps/app.xml\"/>\
             </Relationships>"
        )
        .as_bytes(),
    );

    // Document properties: a title at most; no author, no dates.
    let title_el = if title.is_empty() {
        String::new()
    } else {
        format!("<dc:title>{}</dc:title>", dml_escape(title))
    };
    z.add(
        "docProps/core.xml",
        format!(
            "{XML_DECL}<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" \
             xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" \
             xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\
             {title_el}</cp:coreProperties>"
        )
        .as_bytes(),
    );
    z.add(
        "docProps/app.xml",
        format!(
            "{XML_DECL}<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">\
             <Application>vellum</Application><Slides>{n}</Slides></Properties>"
        )
        .as_bytes(),
    );

    // The presentation: master, slides, size.
    let mut sld_ids = String::new();
    let mut pres_rels = format!(
        "<Relationship Id=\"rId1\" Type=\"{R_DOC}/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
    );
    for i in 1..=n {
        sld_ids.push_str(&format!(
            "<p:sldId id=\"{}\" r:id=\"rId{}\"/>",
            255 + i,
            i + 1
        ));
        pres_rels.push_str(&format!(
            "<Relationship Id=\"rId{}\" Type=\"{R_DOC}/slide\" Target=\"slides/slide{i}.xml\"/>",
            i + 1
        ));
    }
    let k = n + 2;
    pres_rels.push_str(&format!(
        "<Relationship Id=\"rId{}\" Type=\"{R_DOC}/presProps\" Target=\"presProps.xml\"/>\
         <Relationship Id=\"rId{}\" Type=\"{R_DOC}/viewProps\" Target=\"viewProps.xml\"/>\
         <Relationship Id=\"rId{}\" Type=\"{R_DOC}/theme\" Target=\"theme/theme1.xml\"/>\
         <Relationship Id=\"rId{}\" Type=\"{R_DOC}/tableStyles\" Target=\"tableStyles.xml\"/>",
        k,
        k + 1,
        k + 2,
        k + 3
    ));
    z.add(
        "ppt/presentation.xml",
        format!(
            "{XML_DECL}<p:presentation {DML_NS} saveSubsetFonts=\"1\">\
             <p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>\
             <p:sldIdLst>{sld_ids}</p:sldIdLst><p:sldSz cx=\"{cx}\" cy=\"{cy}\"/>\
             <p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        )
        .as_bytes(),
    );
    z.add(
        "ppt/_rels/presentation.xml.rels",
        format!("{XML_DECL}<Relationships xmlns=\"{REL_NS}\">{pres_rels}</Relationships>")
            .as_bytes(),
    );
    z.add(
        "ppt/presProps.xml",
        format!("{XML_DECL}<p:presentationPr {DML_NS}/>").as_bytes(),
    );
    z.add(
        "ppt/viewProps.xml",
        format!("{XML_DECL}<p:viewPr {DML_NS}/>").as_bytes(),
    );
    z.add(
        "ppt/tableStyles.xml",
        format!(
            "{XML_DECL}<a:tblStyleLst xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" \
             def=\"{{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}}\"/>"
        )
        .as_bytes(),
    );

    let empty_tree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
         <p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/>\
         <a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr></p:spTree>";
    z.add(
        "ppt/slideMasters/slideMaster1.xml",
        format!(
            "{XML_DECL}<p:sldMaster {DML_NS}><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>\
             {empty_tree}</p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" \
             accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" \
             hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/>\
             </p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>"
        )
        .as_bytes(),
    );
    z.add(
        "ppt/slideMasters/_rels/slideMaster1.xml.rels",
        format!(
            "{XML_DECL}<Relationships xmlns=\"{REL_NS}\">\
             <Relationship Id=\"rId1\" Type=\"{R_DOC}/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>\
             <Relationship Id=\"rId2\" Type=\"{R_DOC}/theme\" Target=\"../theme/theme1.xml\"/></Relationships>"
        )
        .as_bytes(),
    );
    z.add(
        "ppt/slideLayouts/slideLayout1.xml",
        format!(
            "{XML_DECL}<p:sldLayout {DML_NS} type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\">{empty_tree}</p:cSld>\
             <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        )
        .as_bytes(),
    );
    z.add(
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
        format!(
            "{XML_DECL}<Relationships xmlns=\"{REL_NS}\">\
             <Relationship Id=\"rId1\" Type=\"{R_DOC}/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"
        )
        .as_bytes(),
    );
    z.add("ppt/theme/theme1.xml", theme_xml().as_bytes());

    for (i, (xml, rels)) in slide_xml.iter().enumerate() {
        z.add(&format!("ppt/slides/slide{}.xml", i + 1), xml.as_bytes());
        z.add(
            &format!("ppt/slides/_rels/slide{}.xml.rels", i + 1),
            rels.as_bytes(),
        );
    }
    for (i, png) in media_parts.iter().enumerate() {
        // PNGs are compressed already: store them.
        z.add_stored(&format!("ppt/media/image{}.png", i + 1), png);
    }
    z.finish()
}

/// Give every shape in a fragment a fresh id from 2 up (the slide's shape tree
/// is 1), so ids are unique on the slide as PowerPoint requires.
fn renumber_ids(xml: &str) -> String {
    let key = "<p:cNvPr id=\"";
    let mut out = String::with_capacity(xml.len());
    let mut rest = xml;
    let mut next = 2u32;
    while let Some(i) = rest.find(key) {
        let j = i + key.len();
        out.push_str(&rest[..j]);
        let end = rest[j..].find('"').map(|e| j + e).unwrap_or(rest.len());
        out.push_str(&next.to_string());
        next += 1;
        rest = &rest[end..];
    }
    out.push_str(rest);
    out
}

/// A plain Office theme: the colour, font and format schemes a master needs.
fn theme_xml() -> String {
    let clr = |name: &str, v: &str| format!("<a:{name}><a:srgbClr val=\"{v}\"/></a:{name}>");
    let colours = [
        ("dk1", "000000"),
        ("lt1", "FFFFFF"),
        ("dk2", "44546A"),
        ("lt2", "E7E6E6"),
        ("accent1", "4472C4"),
        ("accent2", "ED7D31"),
        ("accent3", "A5A5A5"),
        ("accent4", "FFC000"),
        ("accent5", "5B9BD5"),
        ("accent6", "70AD47"),
        ("hlink", "0563C1"),
        ("folHlink", "954F72"),
    ]
    .iter()
    .map(|(n, v)| clr(n, v))
    .collect::<String>();
    let font = |face: &str| {
        format!("<a:latin typeface=\"{face}\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>")
    };
    let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>";
    let line = |w: u32| {
        format!(
            "<a:ln w=\"{w}\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\
             <a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        )
    };
    let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>";
    format!(
        "{XML_DECL}<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"vellum\">\
         <a:themeElements><a:clrScheme name=\"Office\">{colours}</a:clrScheme>\
         <a:fontScheme name=\"Office\"><a:majorFont>{maj}</a:majorFont><a:minorFont>{min}</a:minorFont></a:fontScheme>\
         <a:fmtScheme name=\"Office\"><a:fillStyleLst>{fill}{fill}{fill}</a:fillStyleLst>\
         <a:lnStyleLst>{l1}{l2}{l3}</a:lnStyleLst><a:effectStyleLst>{effect}{effect}{effect}</a:effectStyleLst>\
         <a:bgFillStyleLst>{fill}{fill}{fill}</a:bgFillStyleLst></a:fmtScheme></a:themeElements>\
         <a:objectDefaults/><a:extraClrSchemeLst/></a:theme>",
        maj = font("Calibri Light"),
        min = font("Calibri"),
        l1 = line(6350),
        l2 = line(12700),
        l3 = line(19050),
    )
}

/// A zip archive written in one pass: local headers, then the central
/// directory. Every entry carries the same fixed timestamp (1980-01-01 00:00,
/// the format's epoch), so the archive depends on its contents alone.
#[derive(Default)]
struct ZipWriter {
    buf: Vec<u8>,
    central: Vec<u8>,
    count: u16,
}

const DOS_TIME: u16 = 0;
const DOS_DATE: u16 = (1 << 5) | 1; // 1980-01-01

impl ZipWriter {
    fn add(&mut self, name: &str, data: &[u8]) {
        let mut enc = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::new(6));
        enc.write_all(data).expect("deflate into memory");
        let comp = enc.finish().expect("deflate into memory");
        self.entry(name, data, &comp, 8);
    }

    fn add_stored(&mut self, name: &str, data: &[u8]) {
        self.entry(name, data, data, 0);
    }

    fn entry(&mut self, name: &str, raw: &[u8], body: &[u8], method: u16) {
        let mut crc = flate2::Crc::new();
        crc.update(raw);
        let crc = crc.sum();
        let offset = self.buf.len() as u32;
        let name_b = name.as_bytes();
        let le16 = |v: &mut Vec<u8>, x: u16| v.extend_from_slice(&x.to_le_bytes());
        let le32 = |v: &mut Vec<u8>, x: u32| v.extend_from_slice(&x.to_le_bytes());
        // Local file header.
        let b = &mut self.buf;
        le32(b, 0x0403_4b50);
        le16(b, 20);
        le16(b, 0);
        le16(b, method);
        le16(b, DOS_TIME);
        le16(b, DOS_DATE);
        le32(b, crc);
        le32(b, body.len() as u32);
        le32(b, raw.len() as u32);
        le16(b, name_b.len() as u16);
        le16(b, 0);
        b.extend_from_slice(name_b);
        b.extend_from_slice(body);
        // Central directory record.
        let c = &mut self.central;
        le32(c, 0x0201_4b50);
        le16(c, 20);
        le16(c, 20);
        le16(c, 0);
        le16(c, method);
        le16(c, DOS_TIME);
        le16(c, DOS_DATE);
        le32(c, crc);
        le32(c, body.len() as u32);
        le32(c, raw.len() as u32);
        le16(c, name_b.len() as u16);
        le16(c, 0);
        le16(c, 0);
        le16(c, 0);
        le16(c, 0);
        le32(c, 0);
        le32(c, offset);
        c.extend_from_slice(name_b);
        self.count += 1;
    }

    fn finish(mut self) -> Vec<u8> {
        let cd_offset = self.buf.len() as u32;
        let cd_size = self.central.len() as u32;
        self.buf.extend_from_slice(&self.central);
        let b = &mut self.buf;
        b.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        b.extend_from_slice(&0u16.to_le_bytes());
        b.extend_from_slice(&0u16.to_le_bytes());
        b.extend_from_slice(&self.count.to_le_bytes());
        b.extend_from_slice(&self.count.to_le_bytes());
        b.extend_from_slice(&cd_size.to_le_bytes());
        b.extend_from_slice(&cd_offset.to_le_bytes());
        b.extend_from_slice(&0u16.to_le_bytes());
        self.buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_renumbered_from_two() {
        let x = "<p:cNvPr id=\"1\" name=\"a\"/><p:cNvPr id=\"7\" name=\"b\"/>";
        assert_eq!(
            renumber_ids(x),
            "<p:cNvPr id=\"2\" name=\"a\"/><p:cNvPr id=\"3\" name=\"b\"/>"
        );
    }

    #[test]
    fn the_package_is_deterministic_and_a_zip() {
        let s = SlidePart {
            xml: format!("<p:grpSp {DML_NS}><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"x\"/></p:nvGrpSpPr></p:grpSp>"),
            media: vec![vec![1, 2, 3]],
        };
        let a = pptx_package(std::slice::from_ref(&s), 914400, 914400, "t");
        let b = pptx_package(std::slice::from_ref(&s), 914400, 914400, "t");
        assert_eq!(a, b);
        assert_eq!(&a[..4], &[0x50, 0x4b, 0x03, 0x04]);
        // ends with an end-of-central-directory record
        let eocd = a.len() - 22;
        assert_eq!(&a[eocd..eocd + 4], &[0x50, 0x4b, 0x05, 0x06]);
    }
}
