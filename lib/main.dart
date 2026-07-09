import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

// ============================================================================
// CONFIGURAÇÃO
// ============================================================================
// TODO: Substitua pela sua chave de API do Gemini (gerada no Google AI Studio).
// ATENÇÃO: Em Flutter Web essa chave fica visível no código-fonte compilado
// (qualquer pessoa pode abrir o DevTools do navegador e vê-la). Para uso
// pessoal/local isso é aceitável, mas nunca publique esse app publicamente
// com a chave embutida dessa forma — nesse caso, use um backend (Cloud
// Function) para intermediar a chamada ao Gemini.
const String kGeminiApiKey =
    'AIzaSyD8RNLJHuommqkGjrkz8Ar2JGouknSK3Q6o2ToHoOrubekGQ';

// TODO: Preencha com as opções do seu projeto Firebase Web.
// Encontre em: Firebase Console > Configurações do Projeto > Seus apps > Web.
const FirebaseOptions kFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyA-IsXp0jXvQ0YlbCakPu5ypQokAo3Z42Q',
  appId: '1:407851408410:web:1953f04e70f2e1eff2c5a3',
  messagingSenderId: '407851408410',
  projectId: 'comanda-e1db3',
  authDomain: 'comanda-e1db3.firebaseapp.com',
  storageBucket: 'comanda-e1db3.firebasestorage.app',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: kFirebaseOptions);
  runApp(const DeliveryApp());
}

class DeliveryApp extends StatelessWidget {
  const DeliveryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Painel de Entregas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final CollectionReference _pedidosRef = FirebaseFirestore.instance.collection(
    'pedidos',
  );

  // Controla o overlay de carregamento enquanto a IA processa a comanda.
  bool _processando = false;

  // Abre o Google Maps ou app de mapas no celular com o endereço do cliente.
  Future<void> _tracarRota(String endereco) async {
    final query = Uri.encodeComponent(endereco);
    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$query',
    );
    final androidUrl = Uri.parse('geo:0,0?q=$query');

    final useUrl = !kIsWeb && await canLaunchUrl(androidUrl) ? androidUrl : url;
    final launchMode = kIsWeb
        ? LaunchMode.platformDefault
        : LaunchMode.externalApplication;

    if (await canLaunchUrl(useUrl)) {
      await launchUrl(useUrl, mode: launchMode);
    } else {
      _mostrarErro('Não foi possível abrir o Google Maps.');
    }
  }

  // Marca o pedido como entregue e grava o horário do servidor.
  Future<void> _marcarComoEntregue(String docId) async {
    try {
      await _pedidosRef.doc(docId).update({
        'status': 'entregue',
        'horario_entrega': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _mostrarErro('Erro ao atualizar pedido: $e');
    }
  }

  // Captura a foto da comanda, envia para o Gemini e permite revisar os dados antes de salvar.
  Future<void> _capturarComandaEProcessar() async {
    final ImagePicker picker = ImagePicker();

    final XFile? imagem = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );

    if (imagem == null) return;

    setState(() => _processando = true);

    try {
      final Uint8List bytes = await imagem.readAsBytes();
      final dadosExtraidos = await _extrairDadosComGemini(bytes);

      if (dadosExtraidos != null && mounted) {
        await _mostrarRevisaoPedido(dadosExtraidos);
      }
    } catch (e) {
      _mostrarErro('Erro ao processar comanda: $e');
    } finally {
      if (mounted) setState(() => _processando = false);
    }
  }

  Future<void> _mostrarRevisaoPedido(
    Map<String, dynamic> dadosExtraidos,
  ) async {
    final nomeController = TextEditingController(
      text: dadosExtraidos['nome']?.toString() ?? '',
    );
    final telefoneController = TextEditingController(
      text: dadosExtraidos['telefone']?.toString() ?? '',
    );
    final enderecoController = TextEditingController(
      text: dadosExtraidos['endereco']?.toString() ?? '',
    );
    final valorController = TextEditingController(
      text: dadosExtraidos['valor_total']?.toString() ?? '',
    );
    final formKey = GlobalKey<FormState>();

    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Revisar pedido extraído'),
            content: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nomeController,
                      decoration: const InputDecoration(labelText: 'Nome'),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe o nome do cliente.';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: telefoneController,
                      decoration: const InputDecoration(labelText: 'Telefone'),
                      keyboardType: TextInputType.phone,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe um telefone.';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: enderecoController,
                      decoration: const InputDecoration(labelText: 'Endereço'),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe o endereço.';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: valorController,
                      decoration: const InputDecoration(
                        labelText: 'Valor total',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe o valor total.';
                        }
                        final normalized = value.replaceAll(',', '.').trim();
                        if (double.tryParse(normalized) == null) {
                          return 'Valor inválido.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.of(context).pop(true);
                  }
                },
                child: const Text('Salvar pedido'),
              ),
            ],
          );
        },
      );

      if (saved == true) {
        await _salvarPedido(
          nomeController.text.trim(),
          telefoneController.text.trim(),
          enderecoController.text.trim(),
          valorController.text.trim().replaceAll(',', '.'),
        );
      }
    } finally {
      nomeController.dispose();
      telefoneController.dispose();
      enderecoController.dispose();
      valorController.dispose();
    }
  }

  Future<void> _adicionarPedidoManual() async {
    final nomeController = TextEditingController();
    final telefoneController = TextEditingController();
    final enderecoController = TextEditingController();
    final valorController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Adicionar pedido manualmente'),
            content: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nomeController,
                      decoration: const InputDecoration(labelText: 'Nome'),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe o nome do cliente.';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: telefoneController,
                      decoration: const InputDecoration(labelText: 'Telefone'),
                      keyboardType: TextInputType.phone,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe um telefone.';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: enderecoController,
                      decoration: const InputDecoration(labelText: 'Endereço'),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe o endereço.';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: valorController,
                      decoration: const InputDecoration(
                        labelText: 'Valor total',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Informe o valor total.';
                        }
                        final normalized = value.replaceAll(',', '.').trim();
                        if (double.tryParse(normalized) == null) {
                          return 'Valor inválido.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.of(context).pop(true);
                  }
                },
                child: const Text('Salvar pedido'),
              ),
            ],
          );
        },
      );

      if (saved == true) {
        await _salvarPedido(
          nomeController.text.trim(),
          telefoneController.text.trim(),
          enderecoController.text.trim(),
          valorController.text.trim().replaceAll(',', '.'),
        );
      }
    } finally {
      nomeController.dispose();
      telefoneController.dispose();
      enderecoController.dispose();
      valorController.dispose();
    }
  }

  Future<void> _salvarPedido(
    String nome,
    String telefone,
    String endereco,
    String valorTotal,
  ) async {
    try {
      await _pedidosRef.add({
        'nome': nome,
        'telefone': telefone,
        'endereco': endereco,
        'valor_total': valorTotal,
        'status': 'pendente',
        'criado_em': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pedido cadastrado com sucesso!')),
        );
      }
    } catch (e) {
      _mostrarErro('Erro ao salvar pedido: $e');
    }
  }

  // Envia a imagem para o Gemini 1.5 Flash e retorna os dados em JSON.
  Future<Map<String, dynamic>?> _extrairDadosComGemini(Uint8List bytes) async {
    final model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: kGeminiApiKey,
      generationConfig: GenerationConfig(responseMimeType: 'application/json'),
    );

    const prompt = '''
Você é um assistente especializado em ler comandas manuscritas de pedidos de
entrega, muitas vezes com caligrafia cursiva e abreviações comuns em
endereços brasileiros (ex: "R." para Rua, "Av." para Avenida, "Pç." para
Praça, "Ap." para Apartamento).

Analise a imagem da comanda e extraia EXATAMENTE os seguintes campos:
- nome: nome completo do cliente
- telefone: telefone/celular do cliente (mantenha os dígitos, pode incluir DDD)
- endereco: endereço completo, expandindo abreviações quando possível
  (ex: "R." -> "Rua", "Av." -> "Avenida"), incluindo número e bairro se houver
- valor_total: valor total do pedido, apenas números (use ponto como
  separador decimal, sem "R\$")

Responda ESTRITAMENTE em JSON puro, sem comentários, sem markdown e sem
texto adicional, seguindo exatamente este formato:
{"nome": "", "telefone": "", "endereco": "", "valor_total": ""}
''';

    final content = [
      Content.multi([TextPart(prompt), DataPart('image/jpeg', bytes)]),
    ];

    final response = await model.generateContent(content);
    final texto = response.text;

    if (texto == null || texto.isEmpty) {
      _mostrarErro('O Gemini não retornou nenhum conteúdo.');
      return null;
    }

    try {
      final jsonLimpo = texto
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();

      final Map<String, dynamic> dados = jsonDecode(jsonLimpo);
      return dados;
    } catch (e) {
      _mostrarErro('Não foi possível interpretar o JSON retornado: $texto');
      return null;
    }
  }

  void _mostrarErro(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensagem), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Painel de Entregas')),
      body: Stack(
        children: [
          StreamBuilder<QuerySnapshot>(
            stream: _pedidosRef
                .where('status', isNotEqualTo: 'entregue')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Erro: ${snapshot.error}'));
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snapshot.data?.docs ?? [];

              if (docs.isEmpty) {
                return const Center(
                  child: Text(
                    'Nenhum pedido pendente 🎉',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data() as Map<String, dynamic>;

                  final nome = data['nome']?.toString() ?? 'Sem nome';
                  final telefone = data['telefone']?.toString() ?? '';
                  final endereco = data['endereco']?.toString() ?? '';
                  final valorTotal = data['valor_total']?.toString() ?? '';

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            nome,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.phone,
                                size: 16,
                                color: Colors.grey,
                              ),
                              const SizedBox(width: 6),
                              Text(telefone),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.location_on,
                                size: 16,
                                color: Colors.grey,
                              ),
                              const SizedBox(width: 6),
                              Expanded(child: Text(endereco)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.attach_money,
                                size: 16,
                                color: Colors.grey,
                              ),
                              Text(
                                'R\$ $valorTotal',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _tracarRota(endereco),
                                  icon: const Icon(Icons.map),
                                  label: const Text('Traçar Rota'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () => _marcarComoEntregue(doc.id),
                                  icon: const Icon(Icons.check_circle),
                                  label: const Text('Entregue'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
          if (_processando)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Lendo comanda com IA...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _processando ? null : _abrirAcoesNovoPedido,
        icon: const Icon(Icons.add_shopping_cart),
        label: const Text('Novo pedido'),
      ),
    );
  }

  void _abrirAcoesNovoPedido() {
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Capturar comanda'),
                subtitle: const Text(
                  'Use a câmera para extrair os dados com IA',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _capturarComandaEProcessar();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_document),
                title: const Text('Adicionar manualmente'),
                subtitle: const Text('Digite os dados do pedido diretamente'),
                onTap: () {
                  Navigator.of(context).pop();
                  _adicionarPedidoManual();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
