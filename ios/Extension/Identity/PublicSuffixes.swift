import Foundation

// Two-label public suffixes used by `EmailDomains.registrableDomain` (TRIAGE D6: the Swift rule must
// give the same result as the server's `tldts.getDomain(host, { allowPrivateDomains: true })` for the
// bundled cases; parity test: Tests/registrable-domain-parity.json).
//
// Generated with tldts 7.4.15 (the version server/package-lock.json resolves):
// - icann: every "<sld>.<cc>" that tldts reports as an ICANN public suffix, for all two-letter
//   country codes and the second-level labels co com net org edu gov ac or ne go mil gob gouv info biz
//   ltd plc me sch nom gen firm web int in ind id lg ed ad gr nhs bank pro name tv;
// - private: PaaS suffixes from the PSL private section seen in sign-in links (the TRIAGE D6 list plus
//   a few more hosting platforms), each checked with allowPrivateDomains: true.
// Not covered (the server may differ): three-label suffixes, other second-level labels (e.g. Japanese
// prefecture suffixes such as tokyo.jp) and other private suffixes.
enum PublicSuffixes {
    static let icannTwoLabel: Set<String> = set("""
        com.ac net.ac org.ac edu.ac gov.ac mil.ac co.ae net.ae org.ae gov.ae ac.ae mil.ae sch.ae com.af
        net.af org.af edu.af gov.af co.ag com.ag net.ag org.ag nom.ag com.ai net.ai org.ai com.al net.al
        org.al edu.al gov.al mil.al co.am com.am net.am org.am co.ao org.ao edu.ao gov.ao ed.ao com.ar
        net.ar org.ar edu.ar gov.ar mil.ar gob.ar int.ar gov.as co.at ac.at or.at com.au net.au org.au
        edu.au gov.au id.au com.aw co.az com.az net.az org.az edu.az gov.az mil.az info.az biz.az int.az
        pro.az name.az com.ba net.ba org.ba edu.ba gov.ba mil.ba co.bb com.bb net.bb org.bb edu.bb gov.bb
        info.bb biz.bb tv.bb co.bd com.bd net.bd org.bd edu.bd gov.bd ac.bd mil.bd info.bd sch.bd id.bd
        tv.bd ac.be gov.bf com.bh net.bh org.bh edu.bh gov.bh co.bi com.bi org.bi edu.bi or.bi co.bj com.bj
        net.bj org.bj edu.bj info.bj com.bm net.bm org.bm edu.bm gov.bm com.bn net.bn org.bn edu.bn gov.bn
        com.bo net.bo org.bo edu.bo mil.bo gob.bo info.bo web.bo int.bo tv.bo com.br net.br org.br edu.br
        gov.br mil.br ind.br pro.br tv.br com.bs net.bs org.bs edu.bs gov.bs com.bt net.bt org.bt edu.bt
        gov.bt co.bw net.bw org.bw gov.bw ac.bw com.by gov.by mil.by co.bz com.bz net.bz org.bz edu.bz
        gov.bz gov.cd co.ci com.ci net.ci org.ci edu.ci ac.ci or.ci go.ci gouv.ci int.ci ed.ci co.ck com.ck
        net.ck org.ck edu.ck gov.ck ac.ck or.ck ne.ck go.ck mil.ck gob.ck gouv.ck info.ck biz.ck ltd.ck
        plc.ck me.ck sch.ck nom.ck gen.ck firm.ck web.ck int.ck in.ck ind.ck id.ck lg.ck ed.ck ad.ck gr.ck
        nhs.ck bank.ck pro.ck name.ck tv.ck co.cl gov.cl mil.cl gob.cl co.cm com.cm net.cm gov.cm com.cn
        net.cn org.cn edu.cn gov.cn ac.cn mil.cn com.co net.co org.co edu.co gov.co mil.co nom.co co.cr
        ac.cr or.cr go.cr ed.cr com.cu net.cu org.cu edu.cu gob.cu com.cv net.cv org.cv edu.cv int.cv id.cv
        com.cw net.cw org.cw edu.cw gov.cx com.cy net.cy org.cy gov.cy ac.cy mil.cy biz.cy ltd.cy pro.cy
        gov.cz co.dm com.dm net.dm org.dm edu.dm gov.dm com.do net.do org.do edu.do gov.do mil.do gob.do
        web.do com.dz net.dz org.dz edu.dz gov.dz com.ec net.ec org.ec edu.ec gov.ec mil.ec gob.ec info.ec
        pro.ec com.ee org.ee edu.ee gov.ee com.eg net.eg org.eg edu.eg gov.eg ac.eg mil.eg info.eg me.eg
        name.eg tv.eg co.er com.er net.er org.er edu.er gov.er ac.er or.er ne.er go.er mil.er gob.er gouv.er
        info.er biz.er ltd.er plc.er me.er sch.er nom.er gen.er firm.er web.er int.er in.er ind.er id.er
        lg.er ed.er ad.er gr.er nhs.er bank.er pro.er name.er tv.er com.es org.es edu.es gob.es nom.es
        com.et net.et org.et edu.et gov.et info.et biz.et name.et com.fj net.fj org.fj edu.fj gov.fj ac.fj
        mil.fj info.fj biz.fj id.fj pro.fj name.fj co.fk com.fk net.fk org.fk edu.fk gov.fk ac.fk or.fk
        ne.fk go.fk mil.fk gob.fk gouv.fk info.fk biz.fk ltd.fk plc.fk me.fk sch.fk nom.fk gen.fk firm.fk
        web.fk int.fk in.fk ind.fk id.fk lg.fk ed.fk ad.fk gr.fk nhs.fk bank.fk pro.fk name.fk tv.fk com.fm
        net.fm org.fm edu.fm com.fr gouv.fr nom.fr edu.gd gov.gd com.ge net.ge org.ge edu.ge gov.ge co.gg
        net.gg org.gg com.gh net.gh org.gh edu.gh gov.gh mil.gh biz.gh com.gi org.gi edu.gi gov.gi ltd.gi
        co.gl com.gl net.gl org.gl edu.gl com.gn net.gn org.gn edu.gn gov.gn ac.gn com.gp net.gp org.gp
        edu.gp com.gr net.gr org.gr edu.gr gov.gr com.gt net.gt org.gt edu.gt mil.gt gob.gt ind.gt com.gu
        net.gu org.gu edu.gu gov.gu info.gu web.gu co.gy com.gy net.gy org.gy edu.gy gov.gy com.hk net.hk
        org.hk edu.hk gov.hk com.hn net.hn org.hn edu.hn mil.hn gob.hn com.hr name.hr com.ht net.ht org.ht
        edu.ht gouv.ht info.ht firm.ht pro.ht co.hu org.hu info.hu co.id net.id ac.id or.id go.id mil.id
        biz.id sch.id web.id gov.ie co.il net.il org.il gov.il ac.il co.im com.im net.im org.im ac.im tv.im
        co.in com.in net.in org.in edu.in gov.in ac.in mil.in info.in biz.in me.in gen.in firm.in int.in
        ind.in bank.in pro.in tv.in co.io com.io net.io org.io edu.io gov.io mil.io nom.io com.iq net.iq
        org.iq edu.iq gov.iq mil.iq co.ir net.ir org.ir gov.ir ac.ir sch.ir id.ir co.it edu.it gov.it or.it
        go.it me.it gr.it tv.it co.je net.je org.je co.jm com.jm net.jm org.jm edu.jm gov.jm ac.jm or.jm
        ne.jm go.jm mil.jm gob.jm gouv.jm info.jm biz.jm ltd.jm plc.jm me.jm sch.jm nom.jm gen.jm firm.jm
        web.jm int.jm in.jm ind.jm id.jm lg.jm ed.jm ad.jm gr.jm nhs.jm bank.jm pro.jm name.jm tv.jm com.jo
        net.jo org.jo edu.jo gov.jo mil.jo sch.jo tv.jo co.jp ac.jp or.jp ne.jp go.jp lg.jp ed.jp ad.jp
        gr.jp co.ke ac.ke or.ke ne.ke go.ke info.ke me.ke com.kg net.kg org.kg edu.kg gov.kg mil.kg com.kh
        net.kh org.kh edu.kh gov.kh com.ki net.ki org.ki edu.ki gov.ki info.ki biz.ki com.km org.km edu.km
        gov.km mil.km gouv.km nom.km net.kn org.kn edu.kn gov.kn com.kp org.kp edu.kp gov.kp co.kr ac.kr
        or.kr ne.kr go.kr mil.kr me.kr com.kw net.kw org.kw edu.kw gov.kw ind.kw com.ky net.ky org.ky edu.ky
        com.kz net.kz org.kz edu.kz gov.kz mil.kz com.la net.la org.la edu.la gov.la info.la int.la com.lb
        net.lb org.lb edu.lb gov.lb co.lc com.lc net.lc org.lc edu.lc gov.lc com.lk net.lk org.lk edu.lk
        gov.lk ac.lk ltd.lk sch.lk web.lk int.lk com.lr net.lr org.lr edu.lr gov.lr co.ls net.ls org.ls
        edu.ls gov.ls ac.ls info.ls biz.ls gov.lt com.lv net.lv org.lv edu.lv gov.lv mil.lv id.lv com.ly
        net.ly org.ly edu.ly gov.ly plc.ly sch.ly id.ly co.ma net.ma org.ma gov.ma ac.ma co.me net.me org.me
        edu.me gov.me ac.me co.mg com.mg org.mg edu.mg gov.mg mil.mg nom.mg com.mk net.mk org.mk edu.mk
        gov.mk name.mk com.ml net.ml org.ml edu.ml gov.ml ac.ml gouv.ml info.ml co.mm com.mm net.mm org.mm
        edu.mm gov.mm ac.mm or.mm ne.mm go.mm mil.mm gob.mm gouv.mm info.mm biz.mm ltd.mm plc.mm me.mm
        sch.mm nom.mm gen.mm firm.mm web.mm int.mm in.mm ind.mm id.mm lg.mm ed.mm ad.mm gr.mm nhs.mm bank.mm
        pro.mm name.mm tv.mm org.mn edu.mn gov.mn com.mo net.mo org.mo edu.mo gov.mo gov.mr com.ms net.ms
        org.ms edu.ms gov.ms com.mt net.mt org.mt edu.mt co.mu com.mu net.mu org.mu gov.mu ac.mu or.mu
        com.mv net.mv org.mv edu.mv gov.mv mil.mv info.mv biz.mv int.mv pro.mv name.mv co.mw com.mw net.mw
        org.mw edu.mw gov.mw ac.mw biz.mw int.mw com.mx net.mx org.mx edu.mx gob.mx com.my net.my org.my
        edu.my gov.my mil.my biz.my name.my co.mz net.mz org.mz edu.mz gov.mz ac.mz mil.mz co.na com.na
        net.na org.na gov.na nom.nc com.nf net.nf info.nf firm.nf web.nf com.ng net.ng org.ng edu.ng gov.ng
        mil.ng sch.ng name.ng co.ni com.ni net.ni org.ni edu.ni ac.ni mil.ni gob.ni info.ni biz.ni nom.ni
        web.ni int.ni in.ni mil.no co.np com.np net.np org.np edu.np gov.np ac.np or.np ne.np go.np mil.np
        gob.np gouv.np info.np biz.np ltd.np plc.np me.np sch.np nom.np gen.np firm.np web.np int.np in.np
        ind.np id.np lg.np ed.np ad.np gr.np nhs.np bank.np pro.np name.np tv.np com.nr net.nr org.nr edu.nr
        gov.nr info.nr biz.nr co.nz net.nz org.nz ac.nz mil.nz gen.nz co.om com.om net.om org.om edu.om
        gov.om pro.om com.pa net.pa org.pa edu.pa ac.pa gob.pa nom.pa com.pe net.pe org.pe edu.pe mil.pe
        gob.pe nom.pe com.pf org.pf edu.pf co.pg com.pg net.pg org.pg edu.pg gov.pg ac.pg or.pg ne.pg go.pg
        mil.pg gob.pg gouv.pg info.pg biz.pg ltd.pg plc.pg me.pg sch.pg nom.pg gen.pg firm.pg web.pg int.pg
        in.pg ind.pg id.pg lg.pg ed.pg ad.pg gr.pg nhs.pg bank.pg pro.pg name.pg tv.pg com.ph net.ph org.ph
        edu.ph gov.ph mil.ph com.pk net.pk org.pk edu.pk gov.pk ac.pk gob.pk biz.pk web.pk com.pl net.pl
        org.pl edu.pl gov.pl mil.pl info.pl biz.pl nom.pl co.pn net.pn org.pn edu.pn gov.pn com.pr net.pr
        org.pr edu.pr gov.pr ac.pr info.pr biz.pr pro.pr name.pr com.ps net.ps org.ps edu.ps gov.ps com.pt
        net.pt org.pt edu.pt gov.pt int.pt gov.pw com.py net.py org.py edu.py gov.py mil.py com.qa net.qa
        org.qa edu.qa gov.qa mil.qa sch.qa name.qa com.re com.ro org.ro info.ro nom.ro firm.ro co.rs org.rs
        edu.rs gov.rs ac.rs in.rs co.rw net.rw org.rw gov.rw ac.rw mil.rw com.sa net.sa org.sa edu.sa gov.sa
        sch.sa com.sb net.sb org.sb edu.sb gov.sb com.sc net.sc org.sc edu.sc gov.sc com.sd net.sd org.sd
        edu.sd gov.sd info.sd tv.sd org.se ac.se com.sg net.sg org.sg edu.sg gov.sg com.sh net.sh org.sh
        gov.sh mil.sh org.sk com.sl net.sl org.sl edu.sl gov.sl com.sn org.sn edu.sn gouv.sn com.so net.so
        org.so edu.so gov.so me.so co.ss com.ss net.ss org.ss edu.ss gov.ss biz.ss me.ss sch.ss co.st com.st
        net.st org.st edu.st mil.st com.sv org.sv edu.sv gob.sv gov.sx com.sy net.sy org.sy edu.sy gov.sy
        mil.sy co.sz org.sz ac.sz co.th net.th ac.th or.th go.th in.th co.tj com.tj net.tj org.tj edu.tj
        gov.tj go.tj mil.tj biz.tj web.tj int.tj name.tj gov.tl co.tm com.tm net.tm org.tm edu.tm gov.tm
        mil.tm nom.tm com.tn net.tn org.tn gov.tn info.tn ind.tn com.to net.to org.to edu.to gov.to mil.to
        com.tr net.tr org.tr edu.tr gov.tr mil.tr info.tr biz.tr gen.tr web.tr name.tr tv.tr co.tt com.tt
        net.tt org.tt edu.tt gov.tt mil.tt info.tt biz.tt pro.tt name.tt com.tw net.tw org.tw edu.tw gov.tw
        mil.tw co.tz ac.tz or.tz ne.tz go.tz mil.tz info.tz me.tz tv.tz com.ua net.ua org.ua edu.ua gov.ua
        in.ua lg.ua co.ug com.ug org.ug edu.ug gov.ug ac.ug or.ug ne.ug go.ug mil.ug co.uk net.uk org.uk
        gov.uk ac.uk ltd.uk plc.uk me.uk nhs.uk co.us or.us ne.us me.us in.us id.us com.uy net.uy org.uy
        edu.uy mil.uy co.uz com.uz net.uz org.uz com.vc net.vc org.vc edu.vc gov.vc mil.vc co.ve com.ve
        net.ve org.ve edu.ve gov.ve mil.ve gob.ve info.ve nom.ve firm.ve web.ve int.ve edu.vg co.vi com.vi
        net.vi org.vi com.vn net.vn org.vn edu.vn gov.vn ac.vn info.vn biz.vn int.vn id.vn pro.vn name.vn
        com.vu net.vu org.vu edu.vu com.ws net.ws org.ws edu.ws gov.ws com.ye net.ye org.ye edu.ye gov.ye
        mil.ye co.za net.za org.za edu.za gov.za ac.za mil.za nom.za web.za co.zm com.zm net.zm org.zm
        edu.zm gov.zm ac.zm mil.zm info.zm biz.zm sch.zm co.zw org.zw gov.zw ac.zw mil.zw
        """)

    static let privateTwoLabel: Set<String> = set("""
        vercel.app github.io netlify.app pages.dev web.app firebaseapp.com herokuapp.com workers.dev
        azurewebsites.net appspot.com blogspot.com cloudfront.net onrender.com fly.dev gitlab.io surge.sh
        ngrok.io ngrok-free.app replit.app
        """)

    static let twoLabel: Set<String> = icannTwoLabel.union(privateTwoLabel)

    private static func set(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }
}
