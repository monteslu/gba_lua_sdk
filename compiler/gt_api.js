// The gt.* surface visible to gtlua programs, mapped to the C runtime in
// sdk/gt_api.h. Types: "int" | "bool" | "void".

export const GT_FUNCTIONS = {
  cls:   { params: ["int"], ret: "void", c: "gt_cls" },
  box:   { params: ["int", "int", "int", "int", "int"], ret: "void", c: "gt_box" },
  btn:   { params: ["int"], ret: "bool", c: "gt_btn" },
  btnp:  { params: ["int"], ret: "bool", c: "gt_btnp" },
  btn2:  { params: ["int"], ret: "bool", c: "gt_btn2" },
  btnp2: { params: ["int"], ret: "bool", c: "gt_btnp2" },
  ticks: { params: [], ret: "int", c: "(int)gt_ticks", isValue: true },
};

export const GT_CONSTANTS = {
  UP: "GT_UP", DOWN: "GT_DOWN", LEFT: "GT_LEFT", RIGHT: "GT_RIGHT",
  A: "GT_A", B: "GT_B", C: "GT_C", START: "GT_START",
};
