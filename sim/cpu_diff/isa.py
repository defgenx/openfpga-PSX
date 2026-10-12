"""R3000A instruction encoders and a small assembler used by gen_prog.py.

Words are ints. A Code object collects words with labels; branch/jump offsets are patched by `link`.
"""

# register names
R0, AT = 0, 1
K0, K1 = 26, 27
SP, RA = 29, 31

# COP0 register numbers
C0_BPC, C0_BDA, C0_JUMPDEST, C0_DCIC, C0_BADVADDR, C0_BDAM, C0_BPCM = 3, 5, 6, 7, 8, 9, 11
C0_SR, C0_CAUSE, C0_EPC, C0_PRID = 12, 13, 14, 15


def R(funct, rs=0, rt=0, rd=0, sh=0):
    return (rs & 31) << 21 | (rt & 31) << 16 | (rd & 31) << 11 | (sh & 31) << 6 | (funct & 63)


def I(op, rs, rt, imm):
    return (op & 63) << 26 | (rs & 31) << 21 | (rt & 31) << 16 | (imm & 0xFFFF)


def J(op, target_words):
    return (op & 63) << 26 | (target_words & 0x3FFFFFF)


NOP = 0
SLL = lambda rd, rt, sh: R(0x00, 0, rt, rd, sh)
SRL = lambda rd, rt, sh: R(0x02, 0, rt, rd, sh)
SRA = lambda rd, rt, sh: R(0x03, 0, rt, rd, sh)
SLLV = lambda rd, rt, rs: R(0x04, rs, rt, rd)
SRLV = lambda rd, rt, rs: R(0x06, rs, rt, rd)
SRAV = lambda rd, rt, rs: R(0x07, rs, rt, rd)
JR = lambda rs: R(0x08, rs)
JALR = lambda rd, rs: R(0x09, rs, 0, rd)
SYSCALL = R(0x0C)
BREAK = R(0x0D)
MFHI = lambda rd: R(0x10, 0, 0, rd)
MTHI = lambda rs: R(0x11, rs)
MFLO = lambda rd: R(0x12, 0, 0, rd)
MTLO = lambda rs: R(0x13, rs)
MULT = lambda rs, rt: R(0x18, rs, rt)
MULTU = lambda rs, rt: R(0x19, rs, rt)
DIV = lambda rs, rt: R(0x1A, rs, rt)
DIVU = lambda rs, rt: R(0x1B, rs, rt)
ADD = lambda rd, rs, rt: R(0x20, rs, rt, rd)
ADDU = lambda rd, rs, rt: R(0x21, rs, rt, rd)
SUB = lambda rd, rs, rt: R(0x22, rs, rt, rd)
SUBU = lambda rd, rs, rt: R(0x23, rs, rt, rd)
AND = lambda rd, rs, rt: R(0x24, rs, rt, rd)
OR = lambda rd, rs, rt: R(0x25, rs, rt, rd)
XOR = lambda rd, rs, rt: R(0x26, rs, rt, rd)
NOR = lambda rd, rs, rt: R(0x27, rs, rt, rd)
SLT = lambda rd, rs, rt: R(0x2A, rs, rt, rd)
SLTU = lambda rd, rs, rt: R(0x2B, rs, rt, rd)

BLTZ = lambda rs, off: I(0x01, rs, 0, off)
BGEZ = lambda rs, off: I(0x01, rs, 1, off)
BLTZAL = lambda rs, off: I(0x01, rs, 16, off)
BGEZAL = lambda rs, off: I(0x01, rs, 17, off)
BEQ = lambda rs, rt, off: I(0x04, rs, rt, off)
BNE = lambda rs, rt, off: I(0x05, rs, rt, off)
BLEZ = lambda rs, off: I(0x06, rs, 0, off)
BGTZ = lambda rs, off: I(0x07, rs, 0, off)
ADDI = lambda rt, rs, imm: I(0x08, rs, rt, imm)
ADDIU = lambda rt, rs, imm: I(0x09, rs, rt, imm)
SLTI = lambda rt, rs, imm: I(0x0A, rs, rt, imm)
SLTIU = lambda rt, rs, imm: I(0x0B, rs, rt, imm)
ANDI = lambda rt, rs, imm: I(0x0C, rs, rt, imm)
ORI = lambda rt, rs, imm: I(0x0D, rs, rt, imm)
XORI = lambda rt, rs, imm: I(0x0E, rs, rt, imm)
LUI = lambda rt, imm: I(0x0F, 0, rt, imm)
J_ = lambda target_words: J(0x02, target_words)
JAL = lambda target_words: J(0x03, target_words)

LB = lambda rt, off, base: I(0x20, base, rt, off)
LH = lambda rt, off, base: I(0x21, base, rt, off)
LWL = lambda rt, off, base: I(0x22, base, rt, off)
LW = lambda rt, off, base: I(0x23, base, rt, off)
LBU = lambda rt, off, base: I(0x24, base, rt, off)
LHU = lambda rt, off, base: I(0x25, base, rt, off)
LWR = lambda rt, off, base: I(0x26, base, rt, off)
SB = lambda rt, off, base: I(0x28, base, rt, off)
SH = lambda rt, off, base: I(0x29, base, rt, off)
SWL = lambda rt, off, base: I(0x2A, base, rt, off)
SW = lambda rt, off, base: I(0x2B, base, rt, off)
SWR = lambda rt, off, base: I(0x2E, base, rt, off)
LWC2 = lambda rt, off, base: I(0x32, base, rt, off)
SWC2 = lambda rt, off, base: I(0x3A, base, rt, off)

MFC0 = lambda rt, rd: I(0x10, 0, rt, rd << 11)
MTC0 = lambda rt, rd: I(0x10, 4, rt, rd << 11)
RFE = 0x42000010
MFC2 = lambda rt, rd: I(0x12, 0, rt, rd << 11)
CFC2 = lambda rt, rd: I(0x12, 2, rt, rd << 11)
MTC2 = lambda rt, rd: I(0x12, 4, rt, rd << 11)
CTC2 = lambda rt, rd: I(0x12, 6, rt, rd << 11)
COP2CMD = lambda payload: 0x4A000000 | (payload & 0x1FFFFFF)


def li(rd, value):
    """lui/ori pair (2 words) loading a 32-bit constant."""
    value &= 0xFFFFFFFF
    return [LUI(rd, value >> 16), ORI(rd, rd, value & 0xFFFF)]


def li1(rd, value):
    """single-instruction load of a sign-extended 16-bit constant."""
    return [ADDIU(rd, 0, value & 0xFFFF)]


class Code:
    """Words plus labels; `br(op_builder, label)` placeholders are patched by link()."""

    def __init__(self):
        self.w = []
        self.labels = {}
        self.fix = []   # (index, kind, label, builder)

    def __len__(self):
        return len(self.w)

    def emit(self, *words):
        for x in words:
            if isinstance(x, (list, tuple)):
                self.emit(*x)
            else:
                self.w.append(x & 0xFFFFFFFF)
        return self

    def label(self, name):
        assert name not in self.labels, name
        self.labels[name] = len(self.w)

    def br(self, builder, label):
        """builder(off) -> word, offset in words relative to the delay slot (pc+4)."""
        self.fix.append((len(self.w), label, builder))
        self.w.append(0)

    def link(self):
        for idx, label, builder in self.fix:
            off = self.labels[label] - (idx + 1)
            assert -32768 <= off < 32768
            self.w[idx] = builder(off & 0xFFFF) & 0xFFFFFFFF
        self.fix = []
        return self.w
