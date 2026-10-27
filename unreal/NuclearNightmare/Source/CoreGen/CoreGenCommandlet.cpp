#include "CoreGenCommandlet.h"

#include "AssetRegistry/AssetRegistryModule.h"
#include "Blueprint/SlateBlueprintLibrary.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetBlueprintGeneratedClass.h"
#include "Blueprint/WidgetTree.h"
#include "Components/Border.h"
#include "Components/BorderSlot.h"
#include "Components/HorizontalBox.h"
#include "Components/Overlay.h"
#include "Components/OverlaySlot.h"
#include "Components/TextBlock.h"
#include "Components/VerticalBox.h"
#include "Components/Widget.h"
#include "EdGraphSchema_K2.h"
#include "Engine/Blueprint.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "GameFramework/Actor.h"
#include "K2Node_CallFunction.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_MakeStruct.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet/KismetTextLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/CompilerResultsLog.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Misc/PackageName.h"
#include "UObject/SavePackage.h"
#include "WidgetBlueprint.h"

DEFINE_LOG_CATEGORY_STATIC(LogCoreGen, Log, All);

namespace
{
	const FName PN_Then = UEdGraphSchema_K2::PN_Then;
	const FName PN_Exec = UEdGraphSchema_K2::PN_Execute;
	const FName PN_Self = UEdGraphSchema_K2::PN_Self;
	const FName PN_Ret = UEdGraphSchema_K2::PN_ReturnValue;

	FEdGraphPinType PinType(FName Category, UObject* Sub = nullptr)
	{
		FEdGraphPinType T;
		T.PinCategory = Category;
		T.PinSubCategoryObject = Sub;
		return T;
	}
	FEdGraphPinType StrT() { return PinType(UEdGraphSchema_K2::PC_String); }
	/** A Blueprint "Float" (UE5: real, double precision); Lua numbers pass straight in. */
	FEdGraphPinType RealT()
	{
		FEdGraphPinType T = PinType(UEdGraphSchema_K2::PC_Real);
		T.PinSubCategory = UEdGraphSchema_K2::PC_Double;
		return T;
	}
	FEdGraphPinType Vec2T() { return PinType(UEdGraphSchema_K2::PC_Struct, TBaseStructure<FVector2D>::Get()); }
	FEdGraphPinType ObjT(UClass* C) { return PinType(UEdGraphSchema_K2::PC_Object, C); }

	using FParams = TArray<TPair<FName, FEdGraphPinType>>;

	/** Places nodes left to right in one graph and wires them. Any missing pin is a generator bug, so it asserts. */
	struct FGraph
	{
		UBlueprint* BP;
		UEdGraph* G;
		const UEdGraphSchema_K2* K2 = GetDefault<UEdGraphSchema_K2>();
		int32 X = 0;

		FGraph(UBlueprint* InBP, UEdGraph* InG) : BP(InBP), G(InG) {}

		void Place(UEdGraphNode* N) { N->NodePosX = X; N->NodePosY = 0; X += 320; }

		UK2Node_CallFunction* Call(UClass* Owner, FName Fn)
		{
			UFunction* F = Owner->FindFunctionByName(Fn);
			checkf(F, TEXT("No function %s on %s"), *Fn.ToString(), *Owner->GetName());
			FGraphNodeCreator<UK2Node_CallFunction> C(*G);
			UK2Node_CallFunction* N = C.CreateNode(false);
			N->SetFromFunction(F);
			Place(N);
			C.Finalize();
			return N;
		}

		UK2Node_VariableSet* Set(FName Var)
		{
			FGraphNodeCreator<UK2Node_VariableSet> C(*G);
			UK2Node_VariableSet* N = C.CreateNode(false);
			N->VariableReference.SetSelfMember(Var);
			Place(N);
			C.Finalize();
			return N;
		}

		UK2Node_VariableGet* Get(FName Var)
		{
			FGraphNodeCreator<UK2Node_VariableGet> C(*G);
			UK2Node_VariableGet* N = C.CreateNode(false);
			N->VariableReference.SetSelfMember(Var);
			Place(N);
			C.Finalize();
			return N;
		}

		/** A Make <Struct> node; its input pins are named after the struct's members. */
		UK2Node_MakeStruct* MakeStruct(UScriptStruct* Struct)
		{
			FGraphNodeCreator<UK2Node_MakeStruct> C(*G);
			UK2Node_MakeStruct* N = C.CreateNode(false);
			N->StructType = Struct;
			Place(N);
			C.Finalize();
			return N;
		}

		/** The node's one data output pin (a Make <Struct> node names it after the struct). */
		UEdGraphPin* OnlyOutput(UEdGraphNode* N)
		{
			UEdGraphPin* Found = nullptr;
			for (UEdGraphPin* P : N->Pins)
			{
				if (P->Direction == EGPD_Output && P->PinType.PinCategory != UEdGraphSchema_K2::PC_Exec)
				{
					checkf(!Found, TEXT("More than one output pin on %s"), *N->GetNodeTitle(ENodeTitleType::ListView).ToString());
					Found = P;
				}
			}
			checkf(Found, TEXT("No output pin on %s"), *N->GetNodeTitle(ENodeTitleType::ListView).ToString());
			return Found;
		}

		UEdGraphPin* Pin(UEdGraphNode* N, FName Name)
		{
			UEdGraphPin* P = N->FindPin(Name);
			checkf(P, TEXT("No pin %s on %s"), *Name.ToString(), *N->GetNodeTitle(ENodeTitleType::ListView).ToString());
			return P;
		}

		void Link(UEdGraphPin* A, UEdGraphPin* B)
		{
			const bool bOk = K2->TryCreateConnection(A, B);
			checkf(bOk, TEXT("Cannot connect %s -> %s"), *A->GetName(), *B->GetName());
		}
		void Link(UEdGraphNode* A, FName APin, UEdGraphNode* B, FName BPin) { Link(Pin(A, APin), Pin(B, BPin)); }

		/** Wires the exec pins of the given nodes in order, skipping pure nodes. */
		void Chain(std::initializer_list<UEdGraphNode*> Nodes)
		{
			UEdGraphNode* Prev = nullptr;
			for (UEdGraphNode* N : Nodes)
			{
				const bool bHasIn = N->FindPin(PN_Exec) != nullptr;
				const bool bHasOut = N->FindPin(PN_Then) != nullptr;
				if (!bHasIn && !bHasOut)
				{
					continue;
				}
				if (Prev && bHasIn)
				{
					Link(Prev, PN_Then, N, PN_Exec);
				}
				Prev = bHasOut ? N : nullptr;
			}
		}

		void Default(UEdGraphNode* N, FName PinName, const FString& Value) { K2->TrySetDefaultValue(*Pin(N, PinName), Value); }
	};

	struct FFunc
	{
		UEdGraph* G = nullptr;
		UK2Node_FunctionEntry* Entry = nullptr;
		UK2Node_FunctionResult* Result = nullptr;
	};

	FFunc AddFunction(UBlueprint* BP, FName Name, const FParams& In, const FParams& Out)
	{
		FFunc F;
		F.G = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
		FBlueprintEditorUtils::AddFunctionGraph<UClass>(BP, F.G, /*bIsUserCreated*/ true, static_cast<UClass*>(nullptr));
		TArray<UK2Node_FunctionEntry*> Entries;
		F.G->GetNodesOfClass(Entries);
		check(Entries.Num() == 1);
		F.Entry = Entries[0];
		for (const auto& P : In)
		{
			F.Entry->CreateUserDefinedPin(P.Key, P.Value, EGPD_Output, false);
		}
		if (Out.Num() > 0)
		{
			FGraphNodeCreator<UK2Node_FunctionResult> C(*F.G);
			F.Result = C.CreateNode(false);
			F.Result->FunctionReference = F.Entry->FunctionReference;
			F.Result->NodePosX = 1600;
			C.Finalize();
			for (const auto& P : Out)
			{
				F.Result->CreateUserDefinedPin(P.Key, P.Value, EGPD_Input, false);
			}
		}
		return F;
	}

	void ClearGraph(UBlueprint* BP, UEdGraph* G)
	{
		// New Blueprints come with disabled placeholder events (BeginPlay, Tick...); start from an empty graph.
		for (UEdGraphNode* N : TArray<UEdGraphNode*>(G->Nodes))
		{
			FBlueprintEditorUtils::RemoveNode(BP, N, /*bDontRecompile*/ true);
		}
	}

	bool Compile(UBlueprint* BP)
	{
		FCompilerResultsLog Results;
		FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::SkipGarbageCollection, &Results);
		for (const TSharedRef<FTokenizedMessage>& M : Results.Messages)
		{
			UE_LOG(LogCoreGen, Display, TEXT("  [%s] %s"), *BP->GetName(), *M->ToText().ToString());
		}
		if (BP->Status == BS_Error || Results.NumErrors > 0)
		{
			UE_LOG(LogCoreGen, Error, TEXT("%s failed to compile (%d errors)"), *BP->GetPathName(), Results.NumErrors);
			return false;
		}
		return true;
	}

	bool Save(UBlueprint* BP)
	{
		UPackage* Pkg = BP->GetOutermost();
		FAssetRegistryModule::AssetCreated(BP);
		Pkg->MarkPackageDirty();
		const FString File = FPackageName::LongPackageNameToFilename(Pkg->GetName(), FPackageName::GetAssetPackageExtension());
		FSavePackageArgs Args;
		Args.TopLevelFlags = RF_Public | RF_Standalone;
		const bool bOk = UPackage::SavePackage(Pkg, BP, *File, Args);
		UE_LOG(LogCoreGen, Display, TEXT("%s %s -> %s"), bOk ? TEXT("Saved") : TEXT("FAILED to save"), *Pkg->GetName(), *File);
		return bOk;
	}

	UBlueprint* NewBlueprint(const FString& LongName, UClass* Parent, TSubclassOf<UBlueprint> BPClass, TSubclassOf<UBlueprintGeneratedClass> GenClass)
	{
		UPackage* Pkg = CreatePackage(*LongName);
		Pkg->FullyLoad();
		return FKismetEditorUtilities::CreateBlueprint(Parent, Pkg, FName(FPackageName::GetShortName(LongName)), BPTYPE_Normal, BPClass, GenClass, TEXT("CoreGen"));
	}

	/**
	 * WBP_<Core>Text: Border "Background" -> TextBlock "Text" (white, drop shadow, size 18), and three functions:
	 *   SetText(NewText: String)                  Text.SetText(NewText)
	 *   SetBackground(R, G, B, A: Float)          Background.SetBrushColor((R, G, B, A)); A = 0 shows no box
	 *   SetBackgroundPadding(Padding: Float)      Background.SetPadding(Padding on all four sides)
	 * The Border is hit-test invisible and starts at alpha 0 with padding 0, so an unstyled element looks and measures
	 * exactly like the bare TextBlock it replaces. Lua creates it, parents it into a game canvas and calls these; it
	 * carries no logic of its own.
	 *
	 * Story 8 names the padding function SetPadding. UUserWidget already has a native SetPadding(FMargin) (padding
	 * outside the root widget), so a Blueprint function of that name would collide with it; it is SetBackgroundPadding.
	 */
	UWidgetBlueprint* BuildText(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sText"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		for (const TCHAR* Fn : {TEXT("SetText"), TEXT("SetBackground"), TEXT("SetBackgroundPadding")})
		{
			// A name the parent class already has would shadow or clash with it: fail loudly here, not in game.
			checkf(!UUserWidget::StaticClass()->FindFunctionByName(Fn), TEXT("UUserWidget already has a function %s"), Fn);
		}

		UWidgetTree* T = WBP->WidgetTree;
		UBorder* Background = T->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("Background"));
		Background->SetBrushColor(FLinearColor(0.f, 0.f, 0.f, 0.f));
		Background->SetPadding(FMargin(0.f));
		Background->SetVisibility(ESlateVisibility::HitTestInvisible);
		Background->bIsVariable = true;
		T->RootWidget = Background;

		UTextBlock* Text = T->ConstructWidget<UTextBlock>(UTextBlock::StaticClass(), TEXT("Text"));
		Text->SetText(FText::GetEmpty());
		Text->SetColorAndOpacity(FSlateColor(FLinearColor::White));
		Text->SetShadowOffset(FVector2D(1.f, 1.f));
		Text->SetShadowColorAndOpacity(FLinearColor(0.f, 0.f, 0.f, 0.85f));
		FSlateFontInfo Font = Text->GetFont();
		Font.Size = 18;
		Text->SetFont(Font);
		Text->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Text->bIsVariable = true;
		UBorderSlot* TextSlot = CastChecked<UBorderSlot>(Background->AddChild(Text));
		TextSlot->SetPadding(FMargin(0.f));
		TextSlot->SetHorizontalAlignment(HAlign_Fill);
		TextSlot->SetVerticalAlignment(VAlign_Fill);
		WBP->OnVariableAdded(TEXT("Background"));
		WBP->OnVariableAdded(TEXT("Text"));

		// The functions need the compiled widget variables, so compile first.
		FFunc SetText = AddFunction(WBP, TEXT("SetText"), {{TEXT("NewText"), StrT()}}, {});
		FFunc SetBg = AddFunction(WBP, TEXT("SetBackground"),
			{{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}}, {});
		FFunc SetPad = AddFunction(WBP, TEXT("SetBackgroundPadding"), {{TEXT("Padding"), RealT()}}, {});
		if (!Compile(WBP)) return nullptr;
		{
			// SetBackground(R, G, B, A): Background.SetBrushColor(MakeColor(R, G, B, A)).
			FGraph G(WBP, SetBg.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
			G.Link(SetBg.Entry, TEXT("R"), Make, TEXT("R"));
			G.Link(SetBg.Entry, TEXT("G"), Make, TEXT("G"));
			G.Link(SetBg.Entry, TEXT("B"), Make, TEXT("B"));
			G.Link(SetBg.Entry, TEXT("A"), Make, TEXT("A"));
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrushColor));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(Make, PN_Ret, Set, TEXT("InBrushColor"));
			G.Chain({SetBg.Entry, Set});
		}
		{
			// SetBackgroundPadding(Padding): Background.SetPadding(Margin(Padding, Padding, Padding, Padding)).
			FGraph G(WBP, SetPad.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			for (const FName Side : {GET_MEMBER_NAME_CHECKED(FMargin, Left), GET_MEMBER_NAME_CHECKED(FMargin, Top),
			                         GET_MEMBER_NAME_CHECKED(FMargin, Right), GET_MEMBER_NAME_CHECKED(FMargin, Bottom)})
			{
				G.Link(SetPad.Entry, TEXT("Padding"), Margin, Side);
			}
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetPadding));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(G.OnlyOutput(Margin), G.Pin(Set, TEXT("InPadding")));
			G.Chain({SetPad.Entry, Set});
		}
		{
			FGraph G(WBP, SetText.G);
			UK2Node_VariableGet* GetText = G.Get(TEXT("Text"));
			UK2Node_CallFunction* ToText = G.Call(UKismetTextLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetTextLibrary, Conv_StringToText));
			G.Link(SetText.Entry, TEXT("NewText"), ToText, TEXT("InString"));
			UK2Node_CallFunction* Set = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetText));
			G.Link(GetText, TEXT("Text"), Set, PN_Self);
			G.Link(ToText, PN_Ret, Set, TEXT("InText"));
			G.Chain({SetText.Entry, Set});
		}

		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/** Fails loudly when a function name would clash with one UUserWidget already has (shadowing it in game). */
	void CheckNames(std::initializer_list<const TCHAR*> Names)
	{
		for (const TCHAR* Fn : Names)
		{
			checkf(!UUserWidget::StaticClass()->FindFunctionByName(Fn), TEXT("UUserWidget already has a function %s"), Fn);
		}
	}

	/** The panel's and the button's SetBackground(R, G, B, A) and SetBackgroundPadding(Padding), as on the text widget. */
	FFunc AddSetBackground(UBlueprint* BP)
	{
		return AddFunction(BP, TEXT("SetBackground"), {{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}}, {});
	}
	void FillBackground(UWidgetBlueprint* WBP, const FFunc& SetBg, const FFunc& SetPad)
	{
		{
			FGraph G(WBP, SetBg.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
			G.Link(SetBg.Entry, TEXT("R"), Make, TEXT("R"));
			G.Link(SetBg.Entry, TEXT("G"), Make, TEXT("G"));
			G.Link(SetBg.Entry, TEXT("B"), Make, TEXT("B"));
			G.Link(SetBg.Entry, TEXT("A"), Make, TEXT("A"));
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrushColor));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(Make, PN_Ret, Set, TEXT("InBrushColor"));
			G.Chain({SetBg.Entry, Set});
		}
		{
			FGraph G(WBP, SetPad.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			for (const FName Side : {GET_MEMBER_NAME_CHECKED(FMargin, Left), GET_MEMBER_NAME_CHECKED(FMargin, Top),
			                         GET_MEMBER_NAME_CHECKED(FMargin, Right), GET_MEMBER_NAME_CHECKED(FMargin, Bottom)})
			{
				G.Link(SetPad.Entry, TEXT("Padding"), Margin, Side);
			}
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetPadding));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(G.OnlyOutput(Margin), G.Pin(Set, TEXT("InPadding")));
			G.Chain({SetPad.Entry, Set});
		}
	}

	/**
	 * The tag of a panel or a button (stories 14-15): a String variable CoreTag, set by SetTag(NewTag). Not ToolTipText as
	 * on the text widget: a tooltip on a hit-testable widget (a button, or a panel holding one) would show on hover.
	 */
	FFunc AddTag(UBlueprint* BP)
	{
		FBlueprintEditorUtils::AddMemberVariable(BP, TEXT("CoreTag"), StrT(), TEXT(""));
		return AddFunction(BP, TEXT("SetTag"), {{TEXT("NewTag"), StrT()}}, {});
	}
	void FillTag(UBlueprint* BP, const FFunc& SetTag)
	{
		FGraph G(BP, SetTag.G);
		UK2Node_VariableSet* Set = G.Set(TEXT("CoreTag"));
		G.Link(SetTag.Entry, TEXT("NewTag"), Set, TEXT("CoreTag"));
		G.Chain({SetTag.Entry, Set});
	}

	/**
	 * WBP_<Core>Panel (story 14): Border "Background" -> Overlay "Layers" -> [VerticalBox "VBox", HorizontalBox "HBox"].
	 * Lua puts a vertical panel's children into VBox and a horizontal one's into HBox (the other stays empty: zero size),
	 * sets the gap between them as box slot padding, and reorders them by taking them out and adding them back (box
	 * panels only append). Every container is self-hit-test-invisible: a panel never takes a click itself, while buttons
	 * inside it stay clickable. Functions:
	 *   SetBackground(R, G, B, A), SetBackgroundPadding(Padding)   as on the text widget
	 *   SetTag(NewTag: String)                                     CoreTag = NewTag
	 */
	UWidgetBlueprint* BuildPanel(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sPanel"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetBackground"), TEXT("SetBackgroundPadding"), TEXT("SetTag")});

		UWidgetTree* T = WBP->WidgetTree;
		UBorder* Background = T->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("Background"));
		Background->SetBrushColor(FLinearColor(0.f, 0.f, 0.f, 0.f));
		Background->SetPadding(FMargin(0.f));
		Background->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Background->bIsVariable = true;
		T->RootWidget = Background;
		UOverlay* Layers = T->ConstructWidget<UOverlay>(UOverlay::StaticClass(), TEXT("Layers"));
		Layers->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		UBorderSlot* LayersSlot = CastChecked<UBorderSlot>(Background->AddChild(Layers));
		LayersSlot->SetPadding(FMargin(0.f));
		LayersSlot->SetHorizontalAlignment(HAlign_Fill);
		LayersSlot->SetVerticalAlignment(VAlign_Fill);
		UVerticalBox* VBox = T->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VBox"));
		UHorizontalBox* HBox = T->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("HBox"));
		for (UPanelWidget* Box : {static_cast<UPanelWidget*>(VBox), static_cast<UPanelWidget*>(HBox)})
		{
			Box->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
			Box->bIsVariable = true;
			UOverlaySlot* BoxSlot = CastChecked<UOverlaySlot>(Layers->AddChild(Box));
			BoxSlot->SetHorizontalAlignment(HAlign_Fill);
			BoxSlot->SetVerticalAlignment(VAlign_Fill);
		}
		WBP->OnVariableAdded(TEXT("Background"));
		WBP->OnVariableAdded(TEXT("Layers")); // every widget in the tree needs its GUID, variable or not
		WBP->OnVariableAdded(TEXT("VBox"));
		WBP->OnVariableAdded(TEXT("HBox"));

		// The functions need the compiled widget variables, so compile first.
		FFunc SetBg = AddSetBackground(WBP);
		FFunc SetPad = AddFunction(WBP, TEXT("SetBackgroundPadding"), {{TEXT("Padding"), RealT()}}, {});
		FFunc SetTag = AddTag(WBP);
		if (!Compile(WBP)) return nullptr;
		FillBackground(WBP, SetBg, SetPad);
		FillTag(WBP, SetTag);
		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/** <Core>_Call(Request) -> ReturnValue: "bp-default:" + Request. Core's Lua RegisterHooks it and replaces the result. */
	void AddChannel(UBlueprint* BP, const FString& Core)
	{
		FFunc F = AddFunction(BP, FName(Core + TEXT("_Call")), {{TEXT("Request"), StrT()}}, {{PN_Ret, StrT()}});
		FGraph G(BP, F.G);
		UK2Node_CallFunction* Cat = G.Call(UKismetStringLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetStringLibrary, Concat_StrStr));
		G.Default(Cat, TEXT("A"), TEXT("bp-default:"));
		G.Link(F.Entry, TEXT("Request"), Cat, TEXT("B"));
		G.Link(Cat, PN_Ret, F.Result, PN_Ret);
		G.Chain({F.Entry, F.Result});
	}

	/**
	 * Internal geometry functions (not public API): screen rectangles of any widget, in Slate absolute coordinates
	 * (desktop pixels), and absolute -> a widget's local space. Read from the widget's cached geometry, so a widget that
	 * has not been laid out yet reports zeros.
	 *   <Core>_AbsTopLeft(Widget)          = LocalToAbsolute(geo, (0,0))
	 *   <Core>_AbsBottomRight(Widget)      = LocalToAbsolute(geo, LocalSize(geo))
	 *   <Core>_AbsToLocal(Widget, Absolute) = AbsoluteToLocal(geo, Absolute)
	 */
	void AddGeometry(UBlueprint* BP, const FString& Core)
	{
		const FParams WidgetIn = {{TEXT("Widget"), ObjT(UWidget::StaticClass())}};
		{
			FFunc F = AddFunction(BP, FName(Core + TEXT("_AbsTopLeft")), WidgetIn, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* Abs = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, LocalToAbsolute));
			G.Link(Geo, PN_Ret, Abs, TEXT("Geometry"));
			G.Default(Abs, TEXT("LocalCoordinate"), TEXT("(X=0.000000,Y=0.000000)"));
			G.Link(Abs, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, Abs, F.Result});
		}
		{
			FFunc F = AddFunction(BP, FName(Core + TEXT("_AbsBottomRight")), WidgetIn, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* Size = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, GetLocalSize));
			G.Link(Geo, PN_Ret, Size, TEXT("Geometry"));
			UK2Node_CallFunction* Abs = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, LocalToAbsolute));
			G.Link(Geo, PN_Ret, Abs, TEXT("Geometry"));
			G.Link(Size, PN_Ret, Abs, TEXT("LocalCoordinate"));
			G.Link(Abs, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, Size, Abs, F.Result});
		}
		{
			FParams In = WidgetIn;
			In.Add({TEXT("Absolute"), Vec2T()});
			FFunc F = AddFunction(BP, FName(Core + TEXT("_AbsToLocal")), In, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* Local = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, AbsoluteToLocal));
			G.Link(Geo, PN_Ret, Local, TEXT("Geometry"));
			G.Link(F.Entry, TEXT("Absolute"), Local, TEXT("AbsoluteCoordinate"));
			G.Link(Local, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, Local, F.Result});
		}
	}

	/** /Game/Mods/<Core>/ModActor: the channel and the geometry functions. No events: core needs no BeginPlay logic. */
	UBlueprint* BuildActor(const FString& Dir, const FString& Core)
	{
		UBlueprint* BP = NewBlueprint(Dir / TEXT("ModActor"), AActor::StaticClass(), UBlueprint::StaticClass(), UBlueprintGeneratedClass::StaticClass());
		AddChannel(BP, Core);
		AddGeometry(BP, Core);
		ClearGraph(BP, FBlueprintEditorUtils::FindEventGraph(BP));
		if (!Compile(BP) || !Save(BP)) return nullptr;
		return BP;
	}
}

UCoreGenCommandlet::UCoreGenCommandlet()
{
	IsClient = false;
	IsServer = false;
	IsEditor = true;
	LogToConsole = true;
	ShowErrorCount = true;
}

int32 UCoreGenCommandlet::Main(const FString& Params)
{
	FString Core;
	if (!FParse::Value(*Params, TEXT("CoreName="), Core) || Core.IsEmpty())
	{
		UE_LOG(LogCoreGen, Error, TEXT("Pass -CoreName=<mod.json name>"));
		return 1;
	}
	const FString Dir = TEXT("/Game/Mods/") + Core;
	if (!BuildText(Dir, Core)) return 1;
	if (!BuildPanel(Dir, Core)) return 1;
	if (!BuildActor(Dir, Core)) return 1;
	UE_LOG(LogCoreGen, Display, TEXT("CoreGen: all assets for %s generated."), *Core);
	return 0;
}
