// GrannyMod — оффлайн Granny (Unity/IL2CPP), мод-меню для себя.
// Классы и поля взяты из dump__2_.cs. Адреса методов НЕ захардкожены:
// всё ищется по имени через il2cpp API, поэтому переживает обновления игры
// (пока разработчик не переименует классы/поля).
//
// Без джейла и без JIT: хуки ставятся подменой указателя в MethodInfo
// (это обычная память данных, а не код), Unity вызывает FixedUpdate/Update именно так.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#include <string.h>

// ───────────── il2cpp API ─────────────
static void*        (*il2cpp_domain_get)(void);
static void**       (*il2cpp_domain_get_assemblies)(void*, size_t*);
static void*        (*il2cpp_assembly_get_image)(void*);
static const char*  (*il2cpp_image_get_name)(void*);
static void*        (*il2cpp_class_from_name)(void*, const char*, const char*);
static void*        (*il2cpp_class_get_method_from_name)(void*, const char*, int);
static void*        (*il2cpp_class_get_field_from_name)(void*, const char*);
static int          (*il2cpp_field_get_offset)(void*);
static void*        (*il2cpp_thread_attach)(void*);

static bool LoadAPI() {
    NSString *p = [[NSBundle mainBundle].privateFrameworksPath
                   stringByAppendingString:@"/UnityFramework.framework/UnityFramework"];
    void *h = dlopen(p.UTF8String, RTLD_NOW);
    if (!h) return false;
#define L(n) *(void**)&n = dlsym(h, #n); if (!n) return false;
    L(il2cpp_domain_get) L(il2cpp_domain_get_assemblies) L(il2cpp_assembly_get_image)
    L(il2cpp_image_get_name) L(il2cpp_class_from_name) L(il2cpp_class_get_method_from_name)
    L(il2cpp_class_get_field_from_name) L(il2cpp_field_get_offset) L(il2cpp_thread_attach)
#undef L
    return true;
}

static void *FindImage(const char *name) {
    size_t n = 0;
    void **as = il2cpp_domain_get_assemblies(il2cpp_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il2cpp_assembly_get_image(as[i]);
        if (img && !strcmp(il2cpp_image_get_name(img), name)) return img;
    }
    return NULL;
}

static int Off(void *klass, const char *field) {
    void *f = il2cpp_class_get_field_from_name(klass, field);
    return f ? il2cpp_field_get_offset(f) : -1;
}
#define FLT(o, off) (*(float *)((char *)(o) + (off)))
#define BOOL_(o, off) (*(bool *)((char *)(o) + (off)))

// ───────────── состояние меню ─────────────
static struct {
    float grannySpeed = 1.0f;   // 0 = Бабка стоит
    float playerSpeed = 1.0f;
    bool  blind   = false;      // Бабка не видит игрока
    bool  noGrab  = false;      // attackDistance = 0
    bool  noFall  = false;      // нет урона от падения
    bool  sprint  = false;      // бесконечный спринт
} S;
static volatile float g_grannyDist = -1;       // последнее значение distance
static volatile CFAbsoluteTime g_grannySeen = 0;

// офсеты
static int oWalk, oFollow, oAttack, oSee, oHunt, oDist;      // EnemyAIGranny
static int oFwd, oBack, oSide, oFallHurt, oFallDead;         // FPSControllerNEW
static int g_hooks = 0;
static int oSprintGone;                                      // sprintScript

// ───────────── хуки ─────────────
static void (*o_GrannyFU)(void *, void *);
static void h_GrannyFU(void *self, void *mi) {
    static void *last; static float bw, bf, ba;
    if (self != last) { last = self; bw = FLT(self, oWalk); bf = FLT(self, oFollow); ba = FLT(self, oAttack); }
    FLT(self, oWalk)   = bw * S.grannySpeed;
    FLT(self, oFollow) = bf * S.grannySpeed;
    FLT(self, oAttack) = S.noGrab ? 0.f : ba;
    o_GrannyFU(self, mi);
    if (S.blind) { BOOL_(self, oSee) = false; BOOL_(self, oHunt) = false; }
    g_grannyDist = FLT(self, oDist);
    g_grannySeen = CFAbsoluteTimeGetCurrent();
}

static void (*o_PlayerFU)(void *, void *);
static void h_PlayerFU(void *self, void *mi) {
    static void *last; static float bf, bb, bs;
    if (self != last) { last = self; bf = FLT(self, oFwd); bb = FLT(self, oBack); bs = FLT(self, oSide); }
    FLT(self, oFwd) = bf * S.playerSpeed;
    FLT(self, oBack) = bb * S.playerSpeed;
    FLT(self, oSide) = bs * S.playerSpeed;
    if (S.noFall) { FLT(self, oFallHurt) = 1e9f; FLT(self, oFallDead) = 1e9f; }   // порог урона недостижим
    o_PlayerFU(self, mi);
}

static void (*o_SprintUpd)(void *, void *);
static void h_SprintUpd(void *self, void *mi) {
    if (S.sprint) BOOL_(self, oSprintGone) = false;
    o_SprintUpd(self, mi);
    if (S.sprint) BOOL_(self, oSprintGone) = false;
}

static void Hook(void *klass, const char *m, void *rep, void **orig) {
    void *mi = il2cpp_class_get_method_from_name(klass, m, 0);
    if (!mi || !*(void **)mi) { NSLog(@"[GrannyMod] метод не найден: %s", m); return; }
    *orig = *(void **)mi;        // сохраняем оригинал
    *(void **)mi = rep;          // MethodInfo->methodPointer = наш обработчик
    g_hooks++;
}

static void Setup() {
    void *img = FindImage("Assembly-CSharp.dll");
    void *kGranny = il2cpp_class_from_name(img, "", "EnemyAIGranny");
    void *kPlayer = il2cpp_class_from_name(img, "", "FPSControllerNEW");
    void *kSprint = il2cpp_class_from_name(img, "", "sprintScript");
    if (!kGranny || !kPlayer || !kSprint) { NSLog(@"[GrannyMod] классы не найдены"); return; }

    oWalk = Off(kGranny, "walkSpeed");  oFollow = Off(kGranny, "grannysFollowSpeed");
    oAttack = Off(kGranny, "attackDistance"); oSee = Off(kGranny, "seePlayer");
    oHunt = Off(kGranny, "huntPlayer"); oDist = Off(kGranny, "distance");
    oFwd = Off(kPlayer, "forwardSpeed"); oBack = Off(kPlayer, "backwardSpeed");
    oSide = Off(kPlayer, "sidestepSpeed");
    oFallHurt = Off(kPlayer, "fallHurtBad"); oFallDead = Off(kPlayer, "fallDead"); oSprintGone = Off(kSprint, "sprintGone");

    int offs[] = {oWalk,oFollow,oAttack,oSee,oHunt,oDist,oFwd,oBack,oSide,oFallHurt,oFallDead,oSprintGone};
    for (int o : offs) if (o < 0) { NSLog(@"[GrannyMod] поле не найдено — хуки не ставлю"); return; }

    Hook(kGranny, "FixedUpdate",  (void *)h_GrannyFU,  (void **)&o_GrannyFU);
    Hook(kPlayer, "FixedUpdate",  (void *)h_PlayerFU,  (void **)&o_PlayerFU);
    Hook(kSprint, "Update",       (void *)h_SprintUpd, (void **)&o_SprintUpd);
}

// ───────────── меню (UIKit) ─────────────
@interface GMenu : NSObject
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *distLabel;
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

- (UIView *)rowWithTitle:(NSString *)t toggle:(bool *)flag {
    UILabel *l = [UILabel new]; l.text = t; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:14];
    UISwitch *sw = [UISwitch new]; sw.on = *flag;
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) { *flag = sw.on; }] forControlEvents:UIControlEventValueChanged];
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[l, sw]]; r.distribution = UIStackViewDistributionEqualSpacing;
    return r;
}
- (UIView *)rowWithTitle:(NSString *)t slider:(float *)v max:(float)max {
    UILabel *l = [UILabel new]; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:14];
    l.text = [NSString stringWithFormat:@"%@ ×%.1f", t, *v];
    UISlider *s = [UISlider new]; s.minimumValue = 0; s.maximumValue = max; s.value = *v;
    [s addAction:[UIAction actionWithHandler:^(UIAction *a) {
        *v = roundf(s.value * 10) / 10; l.text = [NSString stringWithFormat:@"%@ ×%.1f", t, *v];
    }] forControlEvents:UIControlEventValueChanged];
    UIStackView *r = [[UIStackView alloc] initWithArrangedSubviews:@[l, s]]; r.axis = UILayoutConstraintAxisVertical; r.spacing = 2;
    return r;
}

- (void)install {
    UIWindow *w = [self keyWindow]; if (!w) return;

    self.panel = [[UIView alloc] initWithFrame:CGRectMake(60, 60, 250, 0)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    self.panel.layer.cornerRadius = 12; self.panel.hidden = YES;

    self.distLabel = [UILabel new]; self.distLabel.textColor = UIColor.systemOrangeColor;
    self.distLabel.font = [UIFont boldSystemFontOfSize:14]; self.distLabel.text = @"Бабка: —";
    UILabel *status = [UILabel new]; status.textColor = UIColor.lightGrayColor; status.font = [UIFont systemFontOfSize:11];
    status.text = [NSString stringWithFormat:@"хуки: %d/3", g_hooks];

    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.distLabel, status,
        [self rowWithTitle:@"Скорость Бабки (0 = стоит)" slider:&S.grannySpeed max:2],
        [self rowWithTitle:@"Скорость игрока" slider:&S.playerSpeed max:3],
        [self rowWithTitle:@"Бабка слепая" toggle:&S.blind],
        [self rowWithTitle:@"Бабка не хватает" toggle:&S.noGrab],
        [self rowWithTitle:@"Без урона от падения" toggle:&S.noFall],
        [self rowWithTitle:@"Бесконечный спринт" toggle:&S.sprint],
    ]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 10;
    st.frame = CGRectMake(12, 12, 226, 0);
    CGSize fit = [st systemLayoutSizeFittingSize:CGSizeMake(226, UILayoutFittingCompressedSize.height)
                   withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    st.frame = CGRectMake(12, 12, 226, fit.height);
    [self.panel addSubview:st];
    self.panel.frame = CGRectMake(60, 60, 250, fit.height + 24);

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(10, 60, 40, 40); b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    b.layer.cornerRadius = 20; [b setTitle:@"G" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    __weak GMenu *ws = self;
    [b addAction:[UIAction actionWithHandler:^(UIAction *a) { ws.panel.hidden = !ws.panel.hidden; }]
                forControlEvents:UIControlEventTouchUpInside];

    [w addSubview:self.panel]; [w addSubview:b];

    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        bool alive = CFAbsoluteTimeGetCurrent() - g_grannySeen < 1.0;
        ws.distLabel.text = alive ? [NSString stringWithFormat:@"Бабка: %.1f м", g_grannyDist] : @"Бабка: —";
    }];
}
@end

// ───────────── вход ─────────────
__attribute__((constructor)) static void init() {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ждём, пока Unity поднимет IL2CPP и загрузит Assembly-CSharp
        for (int i = 0; i < 120; i++) {
            [NSThread sleepForTimeInterval:1.0];
            if (!LoadAPI()) continue;
            void *dom = il2cpp_domain_get(); if (!dom) continue;
            il2cpp_thread_attach(dom);
            void *img = FindImage("Assembly-CSharp.dll");
            if (img && il2cpp_class_from_name(img, "", "EnemyAIGranny")) {
                Setup();
                dispatch_async(dispatch_get_main_queue(), ^{ [[GMenu shared] install]; });
                return;
            }
        }
    });
}
