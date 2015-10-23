#ifdef INTERFACE
CLASS(NewMenuDecibelsSlider) EXTENDS(NewMenuSlider)
	METHOD(NewMenuDecibelsSlider, loadCvars, void(entity))
	METHOD(NewMenuDecibelsSlider, saveCvars, void(entity))
	METHOD(NewMenuDecibelsSlider, valueToText, string(entity, float))
ENDCLASS(NewMenuDecibelsSlider)
entity makeNewMenuDecibelsSlider(float, float, float, string);
#endif

#ifdef IMPLEMENTATION

float exp(float x)
{
	float i;
	float t, s;

	s = 1;
	t = 1;
	for(i = 1; i < 100; ++i)
	{
		t *= x;
		t /= i;
		s += t;
	}

	return s;
}

float ln(float x)
{
	float i;
	float r, r0;

	r = 1;
	r0 = 0;
	for(i = 1; fabs(r - r0) >= 0.05; ++i)
	{
		// Newton iteration on exp(r) = x:
		//   r <- r - (exp(r) - x) / (exp(r))
		//   r <- r - 1 + x / exp(r)
		r0 = r;
		r = r0 - 1 + x / exp(r0);
	}
	dprint("ln: ", ftos(i), " iterations\n");

	return r;
}

#define LOG10 2.302585093

entity makeNewMenuDecibelsSlider(float theValueMin, float theValueMax, float theValueStep, string theCvar)
{
	entity me;
	me = spawnNewMenuDecibelsSlider();
	me.configureNewMenuSlider(me, theValueMin, theValueMax, theValueStep, theCvar);
	return me;
}
void loadCvarsNewMenuDecibelsSlider(entity me)
{
	float v;

	if not(me.cvarName)
		return;

	v = cvar(me.cvarName);
	if(v >= 0.98)
		me.value = 0;
	else if(v < 0.0005)
		me.value = -1000000;
	else
		me.value = 0.1 * floor(0.5 + 10.0 * ln(cvar(me.cvarName)) * 10 / LOG10);
}
void saveCvarsNewMenuDecibelsSlider(entity me)
{
	if not(me.cvarName)
		return;

	if(me.value >= -0.1)
		cvar_set(me.cvarName, "1");
	if(me.value < -33)
		cvar_set(me.cvarName, "0");
	else
		cvar_set(me.cvarName, ftos(exp(me.value / 10 * LOG10)));
}

string valueToTextNewMenuDecibelsSlider(entity me, float v)
{
	if(v < -33)
		return "OFF";
	else if(v >= -0.1)
		return "MAX";
	return strcat(valueToTextSlider(me, v), " dB");
}

#endif