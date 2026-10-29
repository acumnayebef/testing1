// Xantapers mod — оффлайн Granny (Unity/IL2CPP). Только для одиночной игры.
// Классы/поля/методы ищутся по именам через il2cpp API (адреса не захардкожены).
// Хуки: подмена MethodInfo->methodPointer (без патча кода, JIT не нужен).
// Вызовы Unity-API: il2cpp_runtime_invoke из потока Unity (внутри хука FixedUpdate).
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <pthread.h>
#include <ctype.h>
#include <stdio.h>

// ───────────── il2cpp API ─────────────
static void*        (*il2cpp_domain_get)(void);
static void**       (*il2cpp_domain_get_assemblies)(void*, size_t*);
static void*        (*il2cpp_assembly_get_image)(void*);
static const char*  (*il2cpp_image_get_name)(void*);
static void*        (*il2cpp_class_from_name)(void*, const char*, const char*);
static void*        (*il2cpp_class_get_method_from_name)(void*, const char*, int);
static void*        (*il2cpp_class_get_field_from_name)(void*, const char*);
static void*        (*il2cpp_class_get_methods)(void*, void**);
static int          (*il2cpp_field_get_offset)(void*);
static void*        (*il2cpp_thread_attach)(void*);
static void*        (*il2cpp_runtime_invoke)(void*, void*, void**, void**);
static void*        (*il2cpp_object_unbox)(void*);
static void*        (*il2cpp_class_get_type)(void*);
static void*        (*il2cpp_type_get_object)(void*);
static const char*  (*il2cpp_method_get_name)(void*);
static unsigned     (*il2cpp_method_get_param_count)(void*);
static void*        (*il2cpp_method_get_param)(void*, unsigned);
static char*        (*il2cpp_type_get_name)(void*);

static bool LoadAPI() {
    NSString *p = [[NSBundle mainBundle].privateFrameworksPath
                   stringByAppendingString:@"/UnityFramework.framework/UnityFramework"];
    void *h = dlopen(p.UTF8String, RTLD_NOW);
    if (!h) return false;
#define L(n) *(void**)&n = dlsym(h, #n); if (!n) return false;
    L(il2cpp_domain_get) L(il2cpp_domain_get_assemblies) L(il2cpp_assembly_get_image)
    L(il2cpp_image_get_name) L(il2cpp_class_from_name) L(il2cpp_class_get_method_from_name)
    L(il2cpp_class_get_field_from_name) L(il2cpp_class_get_methods) L(il2cpp_field_get_offset)
    L(il2cpp_thread_attach) L(il2cpp_runtime_invoke) L(il2cpp_object_unbox) L(il2cpp_class_get_type)
    L(il2cpp_type_get_object) L(il2cpp_method_get_name) L(il2cpp_method_get_param_count)
    L(il2cpp_method_get_param) L(il2cpp_type_get_name)
#undef L
    return true;
}

static void *FindClass(const char *ns, const char *name) {
    size_t n = 0;
    void **as = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il2cpp_assembly_get_image(as[i]);
        void *k = img ? il2cpp_class_from_name(img, ns, name) : NULL;
        if (k) return k;
    }
    return NULL;
}
static void *M(void *k, const char *n, int argc) { return k ? il2cpp_class_get_method_from_name(k, n, argc) : NULL; }
static int Off(void *k, const char *f) {
    void *fi = k ? il2cpp_class_get_field_from_name(k, f) : NULL;
    return fi ? il2cpp_field_get_offset(fi) : -1;
}
// метод по имени, числу параметров и типу параметра #idx (для перегрузок)
static void *MByParam(void *k, const char *name, unsigned argc, unsigned idx, const char *typeName) {
    void *it = NULL, *m;
    while ((m = il2cpp_class_get_methods(k, &it))) {
        if (strcmp(il2cpp_method_get_name(m), name) || il2cpp_method_get_param_count(m) != argc) continue;
        char *tn = il2cpp_type_get_name(il2cpp_method_get_param(m, idx));
        if (tn && !strcmp(tn, typeName)) return m;
    }
    return NULL;
}

#define FLT(o, off) (*(float *)((char *)(o) + (off)))
#define BOOL_(o, off) (*(bool *)((char *)(o) + (off)))
#define PTR(o, off) (*(void **)((char *)(o) + (off)))

struct V3 { float x, y, z; };
struct Q4 { float x, y, z, w; };

static bool Inv(void *m, void *obj, void **args, void **ret = NULL) {
    if (!m) return false;
    void *exc = NULL;
    void *r = il2cpp_runtime_invoke(m, obj, args, &exc);
    if (ret) *ret = r;
    return exc == NULL;
}

// Unity-методы
static void *m_getPos, *m_setPos, *m_getFwd, *m_goTr, *m_goSetActive, *m_goActive;
static void *m_camMain, *m_w2s, *m_ccMove, *m_collEnabled, *m_scrW, *m_scrH, *m_findObjs, *m_instantiate;
static void *k_Inv;   // класс InventoryController

static bool GetV3(void *m, void *obj, V3 *out) {
    void *r = NULL;
    if (!obj || !Inv(m, obj, NULL, &r) || !r) return false;
    *out = *(V3 *)il2cpp_object_unbox(r);
    return true;
}
static bool SetPos(void *tr, V3 p) { void *a[1] = { &p }; return Inv(m_setPos, tr, a); }
static void SetEnabled(void *coll, bool v) { void *a[1] = { &v }; Inv(m_collEnabled, coll, a); }

// ───────────── состояние ─────────────
static struct {
    float grannySpeed = 1.0f, playerSpeed = 1.0f, jumpMul = 1.0f, flySpeed = 6.0f;
    bool blind = false, noGrab = false, noFall = false, sprint = false;
    bool deaf = false, noHit = false, airJump = false;
    bool fly = false, noclip = false, esp = false, espGranny = false, ammo = false;
} S;
static volatile bool  g_up = false, g_down = false;
static volatile int   g_tpReq = -1, g_bringReq = -1, g_bringMode = 0;   // mode: 0 переместить, 1 клонировать
static volatile float g_grannyDist = -1;
static volatile CFAbsoluteTime g_grannySeen = 0, g_msgT = 0, g_espT = 0;
static char g_msg[96] = "";
static void *g_granny = NULL;
static void Msg(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vsnprintf(g_msg, sizeof g_msg, fmt, ap); va_end(ap);
    g_msgT = CFAbsoluteTimeGetCurrent();
}

// ───────────── предметы и точки ─────────────
static const char *kItems[] = {
    "tb1","tb2","tb3","tb4","vas","vas2","safeKey","exitKey","hanglockKey","padlockCode","armborst",
    "weaponKey","screwdriver","planka","battery","playhouseKey","carKey","melon","teddy","kugg1","kugg2",
    "message","brunnsvev","oldShotgun","gunDel1","gunDel2","gunDel3","topplock","carbattery","gascan",
    "wrench","sparkplug","meat","specialkey","book","pepperspray","remote","birdSeed","freezeTrap",
    "wheelCrank","rustyPadlockKey","woodenStick","spiderKey","chainCutter","deadRat","christmasBall",
    "christmasKulaBomb","avbitare","hammare"
};
static const int NI = sizeof(kItems) / sizeof(kItems[0]);
static int itemOff[64], itemHave[64];

static const char *kTp[] = {   // поля EnemyAIGranny типа Transform
    "nav1","nav2","nav3","nav4","nav5","nav6","nav7","nav8","nav9","nav10","nav11","nav12","nav13","nav14","nav15","nav16",
    "bedtargetTemp1","bedtargetTemp2","bedtargetTemp3","coffintargetTemp4","coffintargetTempBY","cartargetTemp",
    "PlayerCoffinPos","PlayerCoffinBYPos","PlayerCarPos"
};
static const int NT = sizeof(kTp) / sizeof(kTp[0]);
static int tpOff[40];

// ESP (из потока Unity → в UI)
struct Esp { float x, y, d; int idx; float w, h; };   // idx = -1: Бабка (рамка w×h в долях экрана)
static Esp g_esp[64]; static int g_espN = 0;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

// ───────────── офсеты ─────────────
static int oWalk, oFollow, oAttack, oSee, oHunt, oDist, oHearP, oHearO, oDontHit, oGrannyTr;
static int oFwd, oBack, oSide, oFallHurt, oFallDead, oJump, oCanJump, oThisTr, oChar, oCamPivot, oJoy, oVelY, oAir;
static int oInX, oSprintGone, oShotLoaded, oHaveShotgun, oHaveArrow, oArrowOK, oHaveCrossbow;
static int g_hooks = 0;

// ───────────── хуки ─────────────
static void (*o_GrannyFU)(void *, void *);
static void h_GrannyFU(void *self, void *mi) {
    static void *last; static float bw, bf, ba;
    if (self != last) { last = self; bw = FLT(self, oWalk); bf = FLT(self, oFollow); ba = FLT(self, oAttack); }
    g_granny = self;
    FLT(self, oWalk)   = bw * S.grannySpeed;
    FLT(self, oFollow) = bf * S.grannySpeed;
    FLT(self, oAttack) = S.noGrab ? 0.f : ba;
    if (S.noHit) BOOL_(self, oDontHit) = true;
    o_GrannyFU(self, mi);
    if (S.blind) { BOOL_(self, oSee) = false; BOOL_(self, oHunt) = false; }
    if (S.deaf)  { BOOL_(self, oHearP) = false; BOOL_(self, oHearO) = false; }
    if (S.noHit) BOOL_(self, oDontHit) = true;
    g_grannyDist = FLT(self, oDist);
    g_grannySeen = CFAbsoluteTimeGetCurrent();
}

static void *FindInventory() {
    void *typ = il2cpp_type_get_object(il2cpp_class_get_type(k_Inv));
    void *a[1] = { typ }, *arr = NULL;
    if (!Inv(m_findObjs, NULL, a, &arr) || !arr) return NULL;
    if (*(uint32_t *)((char *)arr + 0x18) == 0) return NULL;
    return *(void **)((char *)arr + 0x20);
}

static void ComputeESP(void *inv, void *playerTr) {
    void *cam = NULL, *r = NULL;
    if (!Inv(m_camMain, NULL, NULL, &cam) || !cam) return;
    int sw = 0, sh = 0;
    if (Inv(m_scrW, NULL, NULL, &r) && r) sw = *(int *)il2cpp_object_unbox(r);
    if (Inv(m_scrH, NULL, NULL, &r) && r) sh = *(int *)il2cpp_object_unbox(r);
    if (sw <= 0 || sh <= 0) return;
    V3 me; if (!GetV3(m_getPos, playerTr, &me)) return;
    auto proj = [&](V3 p, V3 *out) -> bool {
        void *a[1] = { &p }, *rs = NULL;
        if (!Inv(m_w2s, cam, a, &rs) || !rs) return false;
        *out = *(V3 *)il2cpp_object_unbox(rs); return out->z > 0;
    };
    Esp tmp[64]; int n = 0;

    // Бабка: рамка от ног до головы (≈1.8 м)
    if (S.espGranny && g_granny && oGrannyTr >= 0 && CFAbsoluteTimeGetCurrent() - g_grannySeen < 1.0) {
        void *gt = PTR(g_granny, oGrannyTr); V3 p, feet, head;
        if (gt && GetV3(m_getPos, gt, &p)) {
            V3 hp = { p.x, p.y + 1.8f, p.z };
            if (proj(p, &feet) && proj(hp, &head)) {
                float hpx = fabsf(head.y - feet.y);
                float dx = p.x - me.x, dy = p.y - me.y, dz = p.z - me.z;
                tmp[n++] = { feet.x / sw, 1.0f - ((feet.y + head.y) * 0.5f) / sh, sqrtf(dx*dx + dy*dy + dz*dz), -1,
                             0.5f * hpx / sw, hpx / sh };
            }
        }
    }
    // Предметы
    if (S.esp && inv) {
        for (int i = 0; i < NI && n < 63; i++) {
            if (itemOff[i] < 0) continue;
            void *go = PTR(inv, itemOff[i]); if (!go) continue;
            if (itemHave[i] >= 0 && BOOL_(inv, itemHave[i])) continue;
            void *ra = NULL;
            if (!Inv(m_goActive, go, NULL, &ra) || !ra || !*(bool *)il2cpp_object_unbox(ra)) continue;
            void *tr = NULL; if (!Inv(m_goTr, go, NULL, &tr) || !tr) continue;
            V3 p, sp; if (!GetV3(m_getPos, tr, &p) || !proj(p, &sp)) continue;
            float dx = p.x - me.x, dy = p.y - me.y, dz = p.z - me.z;
            tmp[n++] = { sp.x / sw, 1.0f - sp.y / sh, sqrtf(dx*dx + dy*dy + dz*dz), i, 0, 0 };
        }
    }
    pthread_mutex_lock(&g_mu); memcpy(g_esp, tmp, sizeof(Esp) * n); g_espN = n; pthread_mutex_unlock(&g_mu);
    g_espT = CFAbsoluteTimeGetCurrent();
}

static void (*o_PlayerFU)(void *, void *);
static void h_PlayerFU(void *self, void *mi) {
    static void *last; static float bf, bb, bs, bj; static int frame = 0, ccRe = 0;
    static bool ccOff = false; static void *inv = NULL; static V3 saved; static bool savedOk = false;
    if (self != last) {
        last = self; ccOff = false; inv = NULL; ccRe = 0;
        bf = FLT(self, oFwd); bb = FLT(self, oBack); bs = FLT(self, oSide); bj = FLT(self, oJump);
    }
    frame++;
    FLT(self, oFwd) = bf * S.playerSpeed; FLT(self, oBack) = bb * S.playerSpeed; FLT(self, oSide) = bs * S.playerSpeed;
    FLT(self, oJump) = bj * S.jumpMul;
    if (S.airJump) BOOL_(self, oCanJump) = true;
    if (S.noFall || S.fly || S.noclip) { FLT(self, oFallHurt) = 1e9f; FLT(self, oFallDead) = 1e9f; }

    void *tr = PTR(self, oThisTr), *cc = PTR(self, oChar), *cam = PTR(self, oCamPivot), *joy = PTR(self, oJoy);
    const float dt = 0.02f;
    float up = (g_up ? 1.f : 0.f) - (g_down ? 1.f : 0.f);

    // инвентарь: нужен для ESP, патронов, предметов
    bool needInv = S.esp || S.ammo || g_bringReq >= 0;
    if (needInv && (!inv || frame % 20 == 1)) inv = FindInventory();
    if (!needInv) inv = NULL;

    // ── телепорт ──
    if (g_tpReq >= 0) {
        int r = g_tpReq; g_tpReq = -1; V3 d = {0,0,0}; bool ok = false;
        if (r == 0) { savedOk = GetV3(m_getPos, tr, &saved); Msg(savedOk ? "Место сохранено" : "Не удалось сохранить"); }
        else if (r == 1) { if (savedOk) { d = saved; ok = true; } else Msg("Сначала сохрани место"); }
        else {
            bool alive = g_granny && CFAbsoluteTimeGetCurrent() - g_grannySeen < 1.0;
            if (!alive) Msg("Бабка не найдена в сцене");
            else {
                void *t = NULL;
                if (r == 2) t = PTR(g_granny, oGrannyTr);
                else if (r - 100 >= 0 && r - 100 < NT && tpOff[r - 100] >= 0) t = PTR(g_granny, tpOff[r - 100]);
                if (t && GetV3(m_getPos, t, &d)) { d.y += (r == 2 ? 0.2f : 1.0f); ok = true; }
                else Msg("Точка недоступна");
            }
        }
        if (ok) {
            if (!ccOff && cc) { SetEnabled(cc, false); ccRe = 3; }
            SetPos(tr, d); Msg("Телепорт выполнен");
        }
    }

    // ── предметы ──
    if (g_bringReq >= 0) {
        int i = g_bringReq; g_bringReq = -1;
        void *go = (inv && i < NI && itemOff[i] >= 0) ? PTR(inv, itemOff[i]) : NULL;
        V3 me, f;
        if (!go) Msg("Нет такого предмета в сцене");
        else if (!GetV3(m_getPos, tr, &me) || !GetV3(m_getFwd, cam, &f)) Msg("Нет позиции игрока");
        else {
            float l = sqrtf(f.x*f.x + f.z*f.z); if (l < 0.001f) l = 1;
            V3 d = { me.x + f.x / l * 1.5f, me.y + 0.6f, me.z + f.z / l * 1.5f };
            if (g_bringMode == 1) {
                Q4 q = {0,0,0,1}; void *a[3] = { go, &d, &q }; void *clone = NULL;
                if (Inv(m_instantiate, NULL, a, &clone) && clone) Msg("Клон создан: %s", kItems[i]);
                else Msg("Не удалось клонировать %s", kItems[i]);
            } else {
                bool t = true; void *a[1] = { &t }; void *gtr = NULL;
                if (!Inv(m_goSetActive, go, a) || !Inv(m_goTr, go, NULL, &gtr) || !gtr || !SetPos(gtr, d))
                    Msg("Объект %s уничтожен или недоступен", kItems[i]);
                else Msg("Перемещено: %s", kItems[i]);
            }
        }
    }

    // ── патроны ──
    if (S.ammo && inv) {
        if (oShotLoaded >= 0 && oHaveShotgun >= 0 && BOOL_(inv, oHaveShotgun)) BOOL_(inv, oShotLoaded) = true;
        if (oHaveArrow >= 0 && oHaveCrossbow >= 0 && BOOL_(inv, oHaveCrossbow)) {
            BOOL_(inv, oHaveArrow) = true; if (oArrowOK >= 0) BOOL_(inv, oArrowOK) = true;
        }
    }

    // ── подсветка предметов ──
    if ((S.esp || S.espGranny) && frame % 3 == 0) ComputeESP(inv, tr);
    if (!S.esp && !S.espGranny) { g_espN = 0; }

    // ── полёт / noclip ──
    if (S.fly || S.noclip) { if (oVelY >= 0) FLT(self, oVelY) = 0; if (oAir >= 0) FLT(self, oAir) = 0; }
    if (S.noclip && cc && oInX >= 0) {
        if (!ccOff) { SetEnabled(cc, false); ccOff = true; ccRe = 0; savedOk = GetV3(m_getPos, tr, &saved); }
        V3 f, p;
        if (joy && GetV3(m_getFwd, cam, &f) && GetV3(m_getPos, tr, &p)) {
            float jx = FLT(joy, oInX), jy = FLT(joy, oInX + 4);
            float l = sqrtf(f.x*f.x + f.z*f.z); if (l < 0.001f) l = 1;
            float rx = f.z / l, rz = -f.x / l, sp = S.flySpeed * dt;
            p.x += (f.x * jy + rx * jx) * sp;
            p.y += (f.y * jy + up) * sp;
            p.z += (f.z * jy + rz * jx) * sp;
            SetPos(tr, p);
        }
    } else {
        if (ccOff) { if (cc) SetEnabled(cc, true); ccOff = false; }
        if (S.fly && cc) { V3 mv = { 0, up * S.flySpeed * dt + 0.004f, 0 }; void *a[1] = { &mv }; Inv(m_ccMove, cc, a); }
    }
    if (ccRe > 0 && !ccOff && --ccRe == 0 && cc) SetEnabled(cc, true);

    o_PlayerFU(self, mi);
    if (S.airJump) BOOL_(self, oCanJump) = true;
    if ((S.fly || S.noclip) && oVelY >= 0) FLT(self, oVelY) = 0;
}

static void (*o_SprintUpd)(void *, void *);
static void h_SprintUpd(void *self, void *mi) {
    if (S.sprint) BOOL_(self, oSprintGone) = false;
    o_SprintUpd(self, mi);
    if (S.sprint) BOOL_(self, oSprintGone) = false;
}

static void Hook(void *klass, const char *m, void *rep, void **orig) {
    void *mi = il2cpp_class_get_method_from_name(klass, m, 0);
    if (!mi || !*(void **)mi) { NSLog(@"[Xantapers] метод не найден: %s", m); return; }
    *orig = *(void **)mi; *(void **)mi = rep; g_hooks++;
}

static void Setup() {
    void *kGranny = FindClass("", "EnemyAIGranny"), *kPlayer = FindClass("", "FPSControllerNEW");
    void *kSprint = FindClass("", "sprintScript"), *kJoy = FindClass("", "NewJoystickScript");
    k_Inv = FindClass("", "InventoryController");
    if (!kGranny || !kPlayer || !kSprint || !kJoy || !k_Inv) { NSLog(@"[Xantapers] классы игры не найдены"); return; }

    // Unity
    void *kTr = FindClass("UnityEngine", "Transform"), *kGO = FindClass("UnityEngine", "GameObject");
    void *kCam = FindClass("UnityEngine", "Camera"), *kCC = FindClass("UnityEngine", "CharacterController");
    void *kColl = FindClass("UnityEngine", "Collider"), *kScr = FindClass("UnityEngine", "Screen");
    void *kObj = FindClass("UnityEngine", "Object");
    m_getPos = M(kTr, "get_position", 0); m_setPos = M(kTr, "set_position", 1); m_getFwd = M(kTr, "get_forward", 0);
    m_goTr = M(kGO, "get_transform", 0); m_goSetActive = M(kGO, "SetActive", 1); m_goActive = M(kGO, "get_activeInHierarchy", 0);
    m_camMain = M(kCam, "get_main", 0); m_w2s = M(kCam, "WorldToScreenPoint", 1);
    m_ccMove = M(kCC, "Move", 1); m_collEnabled = M(kColl, "set_enabled", 1);
    m_scrW = M(kScr, "get_width", 0); m_scrH = M(kScr, "get_height", 0);
    m_findObjs = M(kObj, "FindObjectsOfType", 1);
    m_instantiate = kObj ? MByParam(kObj, "Instantiate", 3, 1, "UnityEngine.Vector3") : NULL;
    NSLog(@"[Xantapers] unity api: pos=%p set=%p fwd=%p goTr=%p act=%p cam=%p w2s=%p cc=%p coll=%p find=%p inst=%p",
          m_getPos, m_setPos, m_getFwd, m_goTr, m_goActive, m_camMain, m_w2s, m_ccMove, m_collEnabled, m_findObjs, m_instantiate);

    // поля
    oWalk = Off(kGranny, "walkSpeed"); oFollow = Off(kGranny, "grannysFollowSpeed"); oAttack = Off(kGranny, "attackDistance");
    oSee = Off(kGranny, "seePlayer"); oHunt = Off(kGranny, "huntPlayer"); oDist = Off(kGranny, "distance");
    oHearP = Off(kGranny, "grannyHearPlayer"); oHearO = Off(kGranny, "grannyHearObject"); oDontHit = Off(kGranny, "dontHitPlayer");
    oGrannyTr = Off(kGranny, "myTransform");
    oFwd = Off(kPlayer, "forwardSpeed"); oBack = Off(kPlayer, "backwardSpeed"); oSide = Off(kPlayer, "sidestepSpeed");
    oFallHurt = Off(kPlayer, "fallHurtBad"); oFallDead = Off(kPlayer, "fallDead");
    oJump = Off(kPlayer, "jumpSpeed"); oCanJump = Off(kPlayer, "canJump");
    oThisTr = Off(kPlayer, "thisTransform"); oChar = Off(kPlayer, "character"); oCamPivot = Off(kPlayer, "cameraPivot");
    oJoy = Off(kPlayer, "joystick"); oAir = Off(kPlayer, "timeInAir");
    int v = Off(kPlayer, "velocity"); oVelY = v >= 0 ? v + 4 : -1;
    oInX = Off(kJoy, "<inputDir>k__BackingField");
    oSprintGone = Off(kSprint, "sprintGone");
    oShotLoaded = Off(k_Inv, "oldShotgunLoaded"); oHaveShotgun = Off(k_Inv, "haveoldShotgun");
    oHaveArrow = Off(k_Inv, "haveArrow"); oArrowOK = Off(k_Inv, "armborstArrowOK"); oHaveCrossbow = Off(k_Inv, "havearmborst");
    for (int i = 0; i < NI; i++) {
        itemOff[i] = Off(k_Inv, kItems[i]);
        char hn[80]; snprintf(hn, sizeof hn, "have%s", kItems[i]);
        itemHave[i] = Off(k_Inv, hn);
        if (itemHave[i] < 0) { hn[4] = (char)toupper(hn[4]); itemHave[i] = Off(k_Inv, hn); }
    }
    for (int i = 0; i < NT; i++) tpOff[i] = Off(kGranny, kTp[i]);

    int core[] = { oWalk,oFollow,oAttack,oSee,oHunt,oDist,oHearP,oHearO,oDontHit,oGrannyTr,oFwd,oBack,oSide,
                   oFallHurt,oFallDead,oJump,oCanJump,oThisTr,oChar,oCamPivot,oJoy,oSprintGone };
    for (int o : core) if (o < 0) { NSLog(@"[Xantapers] не найдено базовое поле — хуки не ставлю"); return; }

    Hook(kGranny, "FixedUpdate", (void *)h_GrannyFU,  (void **)&o_GrannyFU);
    Hook(kPlayer, "FixedUpdate", (void *)h_PlayerFU,  (void **)&o_PlayerFU);
    Hook(kSprint, "Update",      (void *)h_SprintUpd, (void **)&o_SprintUpd);
}

// ───────────── меню (UIKit) ─────────────
static NSDictionary *RuNames() {
    return @{ @"exitKey":@"Ключ выхода", @"safeKey":@"Ключ сейфа", @"hanglockKey":@"Ключ навесного замка",
        @"padlockCode":@"Код замка", @"weaponKey":@"Ключ оружия", @"playhouseKey":@"Ключ домика",
        @"carKey":@"Ключ машины", @"specialkey":@"Особый ключ", @"hammare":@"Молоток", @"avbitare":@"Кусачки",
        @"screwdriver":@"Отвёртка", @"planka":@"Доска", @"battery":@"Батарейка", @"carbattery":@"Аккумулятор",
        @"gascan":@"Канистра", @"wrench":@"Гаечный ключ", @"sparkplug":@"Свеча зажигания", @"meat":@"Мясо",
        @"book":@"Книга", @"pepperspray":@"Перцовый баллончик", @"remote":@"Пульт", @"birdSeed":@"Корм для птиц",
        @"freezeTrap":@"Ледяная ловушка", @"wheelCrank":@"Рукоятка колеса", @"oldShotgun":@"Дробовик",
        @"gunDel1":@"Часть ружья 1", @"gunDel2":@"Часть ружья 2", @"gunDel3":@"Часть ружья 3",
        @"armborst":@"Арбалет", @"melon":@"Арбуз", @"teddy":@"Мишка", @"message":@"Записка",
        @"brunnsvev":@"Ворот колодца", @"topplock":@"Верхний замок", @"kugg1":@"Шестерёнка 1", @"kugg2":@"Шестерёнка 2",
        @"vas":@"Ваза 1", @"vas2":@"Ваза 2", @"rustyPadlockKey":@"Ржавый ключ", @"woodenStick":@"Палка",
        @"spiderKey":@"Ключ паука", @"chainCutter":@"Бокорезы для цепи", @"deadRat":@"Дохлая крыса",
        @"christmasBall":@"Ёлочный шар", @"christmasKulaBomb":@"Шар-бомба" };
}
static NSString *ItemTitle(int i) {
    NSString *k = @(kItems[i]); NSString *ru = RuNames()[k];
    return ru ? [NSString stringWithFormat:@"%@ (%@)", ru, k] : k;
}
static NSString *TpTitle(int i) {
    NSString *k = @(kTp[i]);
    if ([k hasPrefix:@"nav"]) return [NSString stringWithFormat:@"Точка обхода %@", [k substringFromIndex:3]];
    NSDictionary *d = @{ @"bedtargetTemp1":@"Кровать 1", @"bedtargetTemp2":@"Кровать 2", @"bedtargetTemp3":@"Кровать 3",
        @"coffintargetTemp4":@"Гроб", @"coffintargetTempBY":@"Гроб (двор)", @"cartargetTemp":@"Машина",
        @"PlayerCoffinPos":@"Место в гробу", @"PlayerCoffinBYPos":@"Место в гробу (двор)", @"PlayerCarPos":@"Место в машине" };
    return d[k] ?: k;
}

#define ACCENT [UIColor colorWithRed:0.58 green:0.38 blue:1.0 alpha:1.0]
#define CARDBG [UIColor colorWithWhite:1.0 alpha:0.07]

@interface GMenu : NSObject
@property (nonatomic, strong) UIView *panel, *overlay, *gBox, *header;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSArray<UIStackView *> *stacks;
@property (nonatomic, strong) NSArray<NSNumber *> *heights;
@property (nonatomic, strong) NSMutableArray<UILabel *> *pool;
@property (nonatomic, strong) UILabel *distLabel, *msgLabel, *gLabel;
+ (instancetype)shared;
- (void)install;
@end

@implementation GMenu
+ (instancetype)shared { static GMenu *g; static dispatch_once_t t; dispatch_once(&t, ^{ g = [GMenu new]; }); return g; }

- (UIWindow *)keyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    return nil;
}
- (UILabel *)label:(NSString *)t size:(CGFloat)sz color:(UIColor *)c {
    UILabel *l = [UILabel new]; l.text = t; l.textColor = c; l.font = [UIFont systemFontOfSize:sz]; l.numberOfLines = 0; return l;
}
- (UIView *)card:(NSString *)title rows:(NSArray<UIView *> *)rows {
    UIView *c = [UIView new]; c.backgroundColor = CARDBG; c.layer.cornerRadius = 12;
    NSMutableArray *v = [NSMutableArray new];
    if (title) {
        UILabel *t = [self label:title.uppercaseString size:11 color:ACCENT];
        t.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold]; [v addObject:t];
    }
    [v addObjectsFromArray:rows];
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:v];
    s.axis = UILayoutConstraintAxisVertical; s.spacing = 10; s.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:c.topAnchor constant:10], [s.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-10],
        [s.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:12], [s.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-12]]];
    return c;
}
- (UIView *)toggle:(NSString *)t flag:(bool *)flag {
    UILabel *l = [self label:t size:14 color:UIColor.whiteColor];
    UISwitch *sw = [UISwitch new]; sw.on = *flag; sw.onTintColor = ACCENT;
    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) { *flag = sw.on; }] forControlEvents:UIControlEventValueChanged];
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[l, sw]]; r.alignment = UIStackViewAlignmentCenter; r.spacing = 8; return r;
}
- (UIView *)slider:(NSString *)t value:(float *)v max:(float)max {
    UILabel *l = [self label:t size:14 color:UIColor.whiteColor];
    UILabel *val = [self label:[NSString stringWithFormat:@"%.1f", *v] size:14 color:ACCENT];
    val.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold]; val.textAlignment = NSTextAlignmentRight;
    [val setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[l, val]];
    UISlider *s = [UISlider new]; s.minimumValue = 0; s.maximumValue = max; s.value = *v; s.minimumTrackTintColor = ACCENT;
    [s addAction:[UIAction actionWithHandler:^(UIAction *a) {
        *v = roundf(s.value * 10) / 10; val.text = [NSString stringWithFormat:@"%.1f", *v];
    }] forControlEvents:UIControlEventValueChanged];
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[top, s]]; r.axis = UILayoutConstraintAxisVertical; r.spacing = 4; return r;
}
- (UIButton *)button:(NSString *)t primary:(BOOL)p block:(void (^)(void))b {
    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    [x setTitle:t forState:UIControlStateNormal]; [x setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:13 weight:p ? UIFontWeightSemibold : UIFontWeightRegular];
    x.backgroundColor = p ? [ACCENT colorWithAlphaComponent:0.85] : [UIColor colorWithWhite:1 alpha:0.08];
    x.layer.cornerRadius = 8;
    if (!p) { x.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft; x.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0); }
    [x.heightAnchor constraintEqualToConstant:34].active = YES;
    if (b) [x addAction:[UIAction actionWithHandler:^(UIAction *a) { b(); }] forControlEvents:UIControlEventTouchUpInside];
    return x;
}
- (UIButton *)hold:(NSString *)t flag:(volatile bool *)f {
    UIButton *x = [self button:t primary:YES block:nil];
    [x addAction:[UIAction actionWithHandler:^(UIAction *a) { *f = true; }] forControlEvents:UIControlEventTouchDown];
    UIControlEvents up = UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel;
    [x addAction:[UIAction actionWithHandler:^(UIAction *a) { *f = false; }] forControlEvents:up];
    return x;
}
- (void)styleSeg:(UISegmentedControl *)c {
    c.selectedSegmentTintColor = ACCENT; c.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [c setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] } forState:UIControlStateNormal];
}
- (UIStackView *)column:(NSArray *)views {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views]; s.axis = UILayoutConstraintAxisVertical; s.spacing = 10; return s;
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = (g.view == self.header) ? self.panel : g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)selectTab:(NSInteger)i {
    CGFloat maxH = MAX(120, self.overlay.bounds.size.height - 190);
    for (NSInteger k = 0; k < 3; k++) self.stacks[k].hidden = (k != i);
    CGFloat fh = self.heights[i].floatValue, h = MIN(fh, maxH);
    self.scroll.contentSize = CGSizeMake(262, fh); self.scroll.contentOffset = CGPointZero;
    self.scroll.frame = CGRectMake(14, 86, 262, h);
    CGRect f = self.panel.frame; f.size = CGSizeMake(290, 86 + h + 14); self.panel.frame = f;
}

- (void)install {
    UIWindow *w = [self keyWindow]; if (!w) return;
    __weak GMenu *ws = self;

    // ── оверлей ESP ──
    self.overlay = [[UIView alloc] initWithFrame:w.bounds]; self.overlay.userInteractionEnabled = NO;
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.pool = [NSMutableArray new];
    for (int i = 0; i < 64; i++) {
        UILabel *l = [self label:@"" size:11 color:UIColor.yellowColor]; l.numberOfLines = 1;
        l.font = [UIFont boldSystemFontOfSize:11]; l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        l.layer.cornerRadius = 4; l.clipsToBounds = YES; l.hidden = YES; [self.overlay addSubview:l]; [self.pool addObject:l];
    }
    self.gBox = [UIView new]; self.gBox.layer.borderColor = UIColor.systemRedColor.CGColor; self.gBox.layer.borderWidth = 1.6;
    self.gBox.layer.cornerRadius = 3; self.gBox.hidden = YES; [self.overlay addSubview:self.gBox];
    self.gLabel = [self label:@"" size:12 color:UIColor.whiteColor]; self.gLabel.numberOfLines = 1;
    self.gLabel.font = [UIFont boldSystemFontOfSize:12]; self.gLabel.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.85];
    self.gLabel.layer.cornerRadius = 4; self.gLabel.clipsToBounds = YES; self.gLabel.hidden = YES; [self.overlay addSubview:self.gLabel];
    [w addSubview:self.overlay];

    // ── вкладка «Игра» ──
    self.distLabel = [self label:@"Бабка: —" size:15 color:UIColor.whiteColor];
    self.distLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    self.msgLabel = [self label:[NSString stringWithFormat:@"Хуки: %d/3", g_hooks] size:12 color:[UIColor colorWithWhite:1 alpha:0.55]];
    UIStackView *upDown = [[UIStackView alloc] initWithArrangedSubviews:@[ [self hold:@"▲  Вверх" flag:&g_up], [self hold:@"▼  Вниз" flag:&g_down] ]];
    upDown.distribution = UIStackViewDistributionFillEqually; upDown.spacing = 8;
    UIStackView *t0 = [self column:@[
        [self card:@"Статус" rows:@[ self.distLabel, self.msgLabel ]],
        [self card:@"Визуал" rows:@[ [self toggle:@"ESP: Бабка (рамка)" flag:&S.espGranny], [self toggle:@"ESP: предметы" flag:&S.esp] ]],
        [self card:@"Бабка" rows:@[ [self slider:@"Скорость (0 = стоит)" value:&S.grannySpeed max:2],
            [self toggle:@"Слепая" flag:&S.blind], [self toggle:@"Глухая" flag:&S.deaf],
            [self toggle:@"Не хватает" flag:&S.noGrab], [self toggle:@"Не бьёт" flag:&S.noHit] ]],
        [self card:@"Игрок" rows:@[ [self slider:@"Скорость" value:&S.playerSpeed max:3], [self slider:@"Высота прыжка" value:&S.jumpMul max:3],
            [self toggle:@"Прыжок в воздухе" flag:&S.airJump], [self toggle:@"Без урона от падения" flag:&S.noFall],
            [self toggle:@"Бесконечный спринт" flag:&S.sprint], [self toggle:@"Бесконечные патроны" flag:&S.ammo] ]],
        [self card:@"Полёт" rows:@[ [self toggle:@"Полёт" flag:&S.fly], [self toggle:@"Noclip (сквозь стены)" flag:&S.noclip],
            [self slider:@"Скорость полёта" value:&S.flySpeed max:20], upDown ]],
    ]];

    // ── вкладка «Предметы» ──
    UISegmentedControl *mode = [[UISegmentedControl alloc] initWithItems:@[@"Переместить", @"Клонировать"]];
    mode.selectedSegmentIndex = 0; [self styleSeg:mode];
    [mode addAction:[UIAction actionWithHandler:^(UIAction *a) { g_bringMode = (int)mode.selectedSegmentIndex; }] forControlEvents:UIControlEventValueChanged];
    NSMutableArray *items = [NSMutableArray new];
    for (int i = 0; i < NI; i++) { int idx = i; [items addObject:[self button:ItemTitle(i) primary:NO block:^{ g_bringReq = idx; }]]; }
    UIStackView *t1 = [self column:@[
        [self card:@"Режим" rows:@[ [self label:@"Нажми на предмет — он появится перед тобой." size:12 color:[UIColor colorWithWhite:1 alpha:0.6]], mode ]],
        [self card:@"Предметы" rows:items ] ]];

    // ── вкладка «Телепорт» ──
    NSMutableArray *pts = [NSMutableArray new];
    for (int i = 0; i < NT; i++) { int idx = i; [pts addObject:[self button:TpTitle(i) primary:NO block:^{ g_tpReq = 100 + idx; }]]; }
    UIStackView *t2 = [self column:@[
        [self card:@"Быстрый" rows:@[ [self button:@"Сохранить моё место" primary:YES block:^{ g_tpReq = 0; }],
            [self button:@"Вернуться на сохранённое" primary:YES block:^{ g_tpReq = 1; }],
            [self button:@"К Бабке" primary:YES block:^{ g_tpReq = 2; }] ]],
        [self card:@"Точки Бабки" rows:pts] ]];

    self.stacks = @[t0, t1, t2];
    NSMutableArray *hs = [NSMutableArray new];
    self.scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(14, 86, 262, 100)];
    self.scroll.showsVerticalScrollIndicator = NO;
    for (UIStackView *s in self.stacks) {
        CGSize fit = [s systemLayoutSizeFittingSize:CGSizeMake(262, UILayoutFittingCompressedSize.height)
                      withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        s.frame = CGRectMake(0, 0, 262, fit.height); [hs addObject:@(fit.height)]; [self.scroll addSubview:s];
    }
    self.heights = hs;

    // ── панель ──
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(60, 30, 290, 300)];
    self.panel.layer.cornerRadius = 18; self.panel.hidden = YES;
    self.panel.layer.borderWidth = 1; self.panel.layer.borderColor = [ACCENT colorWithAlphaComponent:0.55].CGColor;
    self.panel.layer.shadowColor = ACCENT.CGColor; self.panel.layer.shadowOpacity = 0.35; self.panel.layer.shadowRadius = 14; self.panel.layer.shadowOffset = CGSizeZero;
    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    bg.frame = CGRectMake(0, 0, 290, 300); bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.layer.cornerRadius = 18; bg.clipsToBounds = YES; bg.contentView.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.6];
    [self.panel addSubview:bg];

    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 290, 44)];
    UILabel *title = [self label:@"Xantapers mod" size:17 color:UIColor.whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy]; title.frame = CGRectMake(16, 8, 170, 28);
    UILabel *sub = [self label:@"Granny" size:11 color:ACCENT]; sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    sub.frame = CGRectMake(150, 14, 80, 16); sub.textAlignment = NSTextAlignmentLeft;
    CGSize ts = [title sizeThatFits:CGSizeMake(200, 28)]; sub.frame = CGRectMake(16 + ts.width + 6, 15, 80, 16);
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; close.frame = CGRectMake(290 - 44, 4, 36, 36);
    [close setTitle:@"✕" forState:UIControlStateNormal]; [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateNormal];
    [close addAction:[UIAction actionWithHandler:^(UIAction *a) { ws.panel.hidden = YES; }] forControlEvents:UIControlEventTouchUpInside];
    [self.header addSubview:title]; [self.header addSubview:sub]; [self.header addSubview:close];
    [self.header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [self.panel addSubview:self.header];

    UISegmentedControl *tabs = [[UISegmentedControl alloc] initWithItems:@[@"Игра", @"Предметы", @"Телепорт"]];
    tabs.frame = CGRectMake(14, 46, 262, 32); tabs.selectedSegmentIndex = 0; [self styleSeg:tabs];
    [tabs addAction:[UIAction actionWithHandler:^(UIAction *a) { [ws selectTab:tabs.selectedSegmentIndex]; }] forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:tabs]; [self.panel addSubview:self.scroll];

    // ── плавающая кнопка ──
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    fab.frame = CGRectMake(8, 30, 46, 46); fab.backgroundColor = [ACCENT colorWithAlphaComponent:0.92]; fab.layer.cornerRadius = 23;
    fab.layer.shadowColor = ACCENT.CGColor; fab.layer.shadowOpacity = 0.6; fab.layer.shadowRadius = 8; fab.layer.shadowOffset = CGSizeZero;
    [fab setTitle:@"X" forState:UIControlStateNormal]; [fab setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy];
    [fab addAction:[UIAction actionWithHandler:^(UIAction *a) { ws.panel.hidden = !ws.panel.hidden; }] forControlEvents:UIControlEventTouchUpInside];
    [fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [w addSubview:self.panel]; [w addSubview:fab];
    [self selectTab:0];

    __block int tick = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        GMenu *s = ws; if (!s) return;
        Esp tmp[64]; int n = 0;
        if ((S.esp || S.espGranny) && CFAbsoluteTimeGetCurrent() - g_espT < 0.5) {
            pthread_mutex_lock(&g_mu); n = g_espN; memcpy(tmp, g_esp, sizeof(Esp) * n); pthread_mutex_unlock(&g_mu);
        }
        CGSize sz = s.overlay.bounds.size; int used = 0; bool gShown = false;
        for (int i = 0; i < n; i++) {
            if (tmp[i].idx < 0) {
                CGFloat bw = tmp[i].w * sz.width, bh = tmp[i].h * sz.height, cx = tmp[i].x * sz.width, cy = tmp[i].y * sz.height;
                s.gBox.frame = CGRectMake(cx - bw / 2, cy - bh / 2, bw, bh); s.gBox.hidden = NO;
                s.gLabel.text = [NSString stringWithFormat:@" БАБКА  %.0f м ", tmp[i].d]; [s.gLabel sizeToFit];
                s.gLabel.center = CGPointMake(cx, cy - bh / 2 - 10); s.gLabel.hidden = NO; gShown = true;
            } else if (used < 64) {
                UILabel *l = s.pool[used++]; l.hidden = NO;
                l.text = [NSString stringWithFormat:@" %@  %.0f м ", ItemTitle(tmp[i].idx), tmp[i].d]; [l sizeToFit];
                l.center = CGPointMake(tmp[i].x * sz.width, tmp[i].y * sz.height);
            }
        }
        for (int i = used; i < 64; i++) s.pool[i].hidden = YES;
        if (!gShown) { s.gBox.hidden = YES; s.gLabel.hidden = YES; }
        if (++tick % 6 == 0) {
            bool alive = CFAbsoluteTimeGetCurrent() - g_grannySeen < 1.0;
            s.distLabel.text = alive ? [NSString stringWithFormat:@"Бабка: %.1f м", g_grannyDist] : @"Бабка: —";
            if (CFAbsoluteTimeGetCurrent() - g_msgT < 6.0) s.msgLabel.text = [NSString stringWithUTF8String:g_msg];
        }
    }];
}
@end

// ───────────── вход ─────────────
__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 120; i++) {
            [NSThread sleepForTimeInterval:1.0];
            if (!LoadAPI()) continue;
            void *dom = il2cpp_domain_get(); if (!dom) continue;
            il2cpp_thread_attach(dom);
            if (FindClass("", "EnemyAIGranny")) {
                Setup();
                dispatch_async(dispatch_get_main_queue(), ^{ [[GMenu shared] install]; });
                return;
            }
        }
    });
}
